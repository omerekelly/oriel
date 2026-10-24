import Foundation

/// Wire protocol shared by the macOS host and the iOS client.
///
/// Every message is length-prefixed:
///
///     [ UInt32 big-endian length ][ UInt8 type ][ payload ... ]
///
/// `length` counts the type byte plus the payload, so a receiver that has read
/// `length` bytes after the prefix always holds exactly one message.
public enum MessageType: UInt8 {
    case hello       = 0x01   // client -> host
    case displayInfo = 0x02   // host -> client
    case videoConfig = 0x03   // host -> client
    case videoFrame  = 0x10   // host -> client
    case audioFrame  = 0x11   // host -> client
    case audioConfig = 0x12   // host -> client
    case input       = 0x20   // client -> host
    case ping        = 0x21   // both ways
    case setViewport = 0x22   // client -> host
    case viewportState = 0x23 // host -> client (echo of the applied viewport)
    case clipboard   = 0x24   // both ways
    case peers       = 0x25   // host -> client (tailnet inventory)
    case stats       = 0x30   // host -> client
}

public enum ProtocolLimits {
    /// A single frame should never exceed this. Guards against a desynced
    /// stream allocating unbounded memory on the receiving side.
    public static let maxMessageBytes = 24 * 1024 * 1024
    public static let defaultPort: UInt16 = 7801
    public static let version = 1
}

// MARK: - Framing

public enum Framing {
    public static func packet(type: MessageType, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    public static func packet<T: Encodable>(type: MessageType, json: T) -> Data {
        let encoder = JSONEncoder()
        let payload = (try? encoder.encode(json)) ?? Data()
        return packet(type: type, payload: payload)
    }
}

/// Reassembles length-prefixed messages from an arbitrarily chunked byte stream.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or nil when more bytes are needed.
    public mutating func next() -> (type: MessageType, payload: Data)? {
        guard buffer.count >= 4 else { return nil }

        let length = buffer.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { dst in
                dst.copyBytes(from: raw.prefix(4))
            }
            return UInt32(bigEndian: value)
        }

        guard length >= 1, length <= UInt32(ProtocolLimits.maxMessageBytes) else {
            // Unrecoverable desync — caller must drop the connection.
            buffer.removeAll(keepingCapacity: false)
            return nil
        }

        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }

        let typeByte = buffer[buffer.index(buffer.startIndex, offsetBy: 4)]
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 5)
        let payloadEnd = buffer.index(buffer.startIndex, offsetBy: total)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)

        guard let type = MessageType(rawValue: typeByte) else { return next() }
        return (type, payload)
    }

    public var isDesynced: Bool {
        buffer.count > ProtocolLimits.maxMessageBytes
    }
}

// MARK: - Control messages (JSON)

public struct Hello: Codable {
    public var version: Int
    public var clientName: String
    /// Pairing code shown by the host. Empty is always rejected.
    public var token: String
    /// Longest edge of the video the client would like, in pixels.
    public var maxDimension: Int
    public var targetFPS: Int

    public init(version: Int = ProtocolLimits.version,
                clientName: String,
                token: String = "",
                maxDimension: Int = 1600,
                targetFPS: Int = 30) {
        self.version = version
        self.clientName = clientName
        self.token = token
        self.maxDimension = maxDimension
        self.targetFPS = targetFPS
    }
}

public struct DisplayInfo: Codable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Point size of the display, used to map incoming normalised cursor
    /// coordinates back onto the real desktop.
    public var pointWidth: Double
    public var pointHeight: Double
    public var name: String
}

public struct VideoConfig: Codable {
    public var codec: String            // "hevc"
    public var width: Int
    public var height: Int
    /// VPS / SPS / PPS, base64 encoded, in order.
    public var parameterSets: [String]
    public var nalUnitHeaderLength: Int
}

public struct AudioConfig: Codable, Equatable {
    public var sampleRate: Double
    public var channels: Int

    public static let defaultPCM = AudioConfig(sampleRate: 48000, channels: 2)

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Audio frame payload: UInt64 host microseconds, then interleaved Int16 PCM.
public enum AudioFrame {
    public static let headerBytes = 8

    public static func encode(micros: Int64, pcm: Data) -> Data {
        var out = Data(capacity: headerBytes + pcm.count)
        var stamp = micros
        withUnsafeBytes(of: &stamp) { out.append(contentsOf: $0) }
        out.append(pcm)
        return out
    }

    public static func pcm(from payload: Data) -> Data {
        guard payload.count > headerBytes else { return Data() }
        return payload.subdata(in: headerBytes..<payload.count)
    }
}

public struct HostStats: Codable {
    public var fps: Double
    public var kbps: Double
    public var audioKbps: Double
    public var clients: Int
    public var capturedWidth: Int
    public var capturedHeight: Int
}

public struct PingMessage: Codable {
    public var sentAtMicros: Int64
    public var echo: Bool
    /// Filled in by the client so the host can adapt its bitrate to the link.
    public var rttMicros: Int64

    public init(sentAtMicros: Int64, echo: Bool, rttMicros: Int64 = 0) {
        self.sentAtMicros = sentAtMicros
        self.echo = echo
        self.rttMicros = rttMicros
    }
}

/// Clipboard contents, exchanged in both directions. Images travel as base64
/// PNG and are capped so a large screenshot cannot stall the video stream.
public struct ClipboardPayload: Codable, Equatable {
    public enum Kind: String, Codable { case text, image }

    public var kind: Kind
    public var text: String?
    public var pngBase64: String?

    public static let maxImageBytes = 4 * 1024 * 1024

    public init(kind: Kind, text: String? = nil, pngBase64: String? = nil) {
        self.kind = kind
        self.text = text
        self.pngBase64 = pngBase64
    }

    public static func text(_ value: String) -> ClipboardPayload {
        ClipboardPayload(kind: .text, text: value)
    }

    public static func image(png: Data) -> ClipboardPayload? {
        guard png.count <= maxImageBytes else { return nil }
        return ClipboardPayload(kind: .image, pngBase64: png.base64EncodedString())
    }

    public var pngData: Data? {
        guard kind == .image, let pngBase64 else { return nil }
        return Data(base64Encoded: pngBase64)
    }
}

/// One device on the tailnet, offered to the client so addresses do not have to
/// be typed by hand.
public struct PeerEntry: Codable, Equatable, Identifiable {
    public var name: String
    public var ip: String
    public var os: String
    public var online: Bool

    public var id: String { ip }

    public init(name: String, ip: String, os: String, online: Bool) {
        self.name = name
        self.ip = ip
        self.os = os
        self.online = online
    }

    public var isMac: Bool { os.lowercased().contains("macos") || os.lowercased() == "mac" }
}

/// Which part of the display is being streamed, as a centre point plus a zoom
/// factor. The host crops its capture to this region at the normal output
/// resolution, so zooming reveals real detail instead of magnifying pixels.
public struct Viewport: Codable, Equatable {
    public var centerX: Double   // 0...1 across the display
    public var centerY: Double   // 0...1 down the display
    public var zoom: Double      // 1 = whole display

    public static let full = Viewport(centerX: 0.5, centerY: 0.5, zoom: 1)
    public static let maxZoom: Double = 4

    public init(centerX: Double, centerY: Double, zoom: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
    }

    /// Normalised rect (x, y, width, height) of the region being streamed.
    public var rect: (x: Double, y: Double, w: Double, h: Double) {
        let side = 1 / max(zoom, 1)
        let x = min(max(centerX - side / 2, 0), 1 - side)
        let y = min(max(centerY - side / 2, 0), 1 - side)
        return (x, y, side, side)
    }

    /// Keeps zoom in range and the crop inside the display.
    public var clamped: Viewport {
        let z = min(max(zoom, 1), Viewport.maxZoom)
        let side = 1 / z
        let x = min(max(centerX - side / 2, 0), 1 - side)
        let y = min(max(centerY - side / 2, 0), 1 - side)
        return Viewport(centerX: x + side / 2, centerY: y + side / 2, zoom: z)
    }

    public var isFullFrame: Bool { zoom <= 1.001 }
}

// MARK: - Video frames

/// Binary layout:
///
///     UInt32 seq | UInt8 flags | Int64 ptsMicros | UInt32 gapMs? | AVCC NAL bytes
///
/// `gapMs` (UInt16) is the time since the previous *sent* frame, which lets the
/// client pace playback and detect a stalled host.
public struct VideoFrameHeader {
    public static let flagsKeyframe: UInt8 = 0x01

    public var sequence: UInt32
    public var flags: UInt8
    public var presentationMicros: Int64
    public var gapMillis: UInt16

    public static let byteCount = 4 + 1 + 8 + 2

    public func encoded() -> Data {
        var out = Data(capacity: VideoFrameHeader.byteCount)
        var seq = sequence.bigEndian
        withUnsafeBytes(of: &seq) { out.append(contentsOf: $0) }
        out.append(flags)
        var pts = presentationMicros
        withUnsafeBytes(of: &pts) { out.append(contentsOf: $0) }
        // Int64 is written little-endian here for speed on both ends; both
        // sides are arm64 and we decode with the same layout.
        var gap = gapMillis.bigEndian
        withUnsafeBytes(of: &gap) { out.append(contentsOf: $0) }
        return out
    }

    public static func decode(_ data: Data) -> VideoFrameHeader? {
        guard data.count >= byteCount else { return nil }
        let base = data.startIndex
        var seq: UInt32 = 0
        data.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &seq) { $0.copyBytes(from: raw[base..<base + 4]) }
        }
        let flags = data[base + 4]
        var pts: Int64 = 0
        data.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &pts) { $0.copyBytes(from: raw[base + 5..<base + 13]) }
        }
        var gap: UInt16 = 0
        data.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &gap) { $0.copyBytes(from: raw[base + 13..<base + 15]) }
        }
        return VideoFrameHeader(sequence: UInt32(bigEndian: seq),
                                flags: flags,
                                presentationMicros: pts,
                                gapMillis: UInt16(bigEndian: gap))
    }
}

// MARK: - Input events

public enum InputEvent: Codable, Equatable {
    case moveRelative(dx: Double, dy: Double)
    case moveAbsolute(x: Double, y: Double)   // normalised 0...1, top-left origin
    case button(button: Int, down: Bool)      // 0 = left, 1 = right
    case scroll(dx: Int, dy: Int)
    case key(code: UInt16, down: Bool, flags: UInt64)
    case text(String)
    case click(x: Double?, y: Double?)        // atomic move + left click
    /// A modifier + key combination, synthesised atomically by the host.
    case chord(code: UInt16, flags: UInt64)
    /// An action the host performs itself, for things that are not reliably
    /// reachable through a keyboard shortcut.
    case hostAction(String)

    private enum CodingKeys: String, CodingKey { case kind, dx, dy, x, y, button, down, code, flags, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "moveRelative": self = .moveRelative(dx: try c.decode(Double.self, forKey: .dx),
                                                 dy: try c.decode(Double.self, forKey: .dy))
        case "moveAbsolute": self = .moveAbsolute(x: try c.decode(Double.self, forKey: .x),
                                                 y: try c.decode(Double.self, forKey: .y))
        case "button": self = .button(button: try c.decode(Int.self, forKey: .button),
                                      down: try c.decode(Bool.self, forKey: .down))
        case "scroll": self = .scroll(dx: try c.decode(Int.self, forKey: .dx),
                                      dy: try c.decode(Int.self, forKey: .dy))
        case "key": self = .key(code: try c.decode(UInt16.self, forKey: .code),
                                down: try c.decode(Bool.self, forKey: .down),
                                flags: try c.decode(UInt64.self, forKey: .flags))
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "click": self = .click(x: try c.decodeIfPresent(Double.self, forKey: .x),
                                    y: try c.decodeIfPresent(Double.self, forKey: .y))
        case "chord": self = .chord(code: try c.decode(UInt16.self, forKey: .code),
                                    flags: try c.decode(UInt64.self, forKey: .flags))
        case "hostAction": self = .hostAction(try c.decode(String.self, forKey: .text))
        default: throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unknown input kind"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .moveRelative(dx, dy):
            try c.encode("moveRelative", forKey: .kind); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .moveAbsolute(x, y):
            try c.encode("moveAbsolute", forKey: .kind); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case let .button(button, down):
            try c.encode("button", forKey: .kind); try c.encode(button, forKey: .button); try c.encode(down, forKey: .down)
        case let .scroll(dx, dy):
            try c.encode("scroll", forKey: .kind); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case let .key(code, down, flags):
            try c.encode("key", forKey: .kind); try c.encode(code, forKey: .code); try c.encode(down, forKey: .down); try c.encode(flags, forKey: .flags)
        case let .text(s):
            try c.encode("text", forKey: .kind); try c.encode(s, forKey: .text)
        case let .click(x, y):
            try c.encode("click", forKey: .kind); try c.encodeIfPresent(x, forKey: .x); try c.encodeIfPresent(y, forKey: .y)
        case let .chord(code, flags):
            try c.encode("chord", forKey: .kind); try c.encode(code, forKey: .code); try c.encode(flags, forKey: .flags)
        case let .hostAction(name):
            try c.encode("hostAction", forKey: .kind); try c.encode(name, forKey: .text)
        }
    }
}

// MARK: - Virtual key codes (HIToolbox values, identical on all Apple keyboards)

public enum VirtualKey {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99

    // Modifiers (as key codes, so the host can emit real down/up transitions)
    public static let command: UInt16 = 55
    public static let shift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let option: UInt16 = 58
    public static let control: UInt16 = 59
    public static let rightCommand: UInt16 = 54
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62

    // Letters, used for shortcut combos
    public static func letter(_ s: Character) -> UInt16? {
        let map: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
            "j": 38, "k": 40, "n": 45, "m": 46
        ]
        return map[s.lowercased().first ?? " "]
    }
}

// MARK: - CGEventFlags raw bits, mirrored so the client does not need AppKit

public enum EventFlags {
    public static let shift: UInt64    = 0x00020000
    public static let control: UInt64  = 0x00040000
    public static let option: UInt64   = 0x00080000
    public static let command: UInt64  = 0x00100000
    public static let fn: UInt64       = 0x00800000
}
