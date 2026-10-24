import Foundation
import Network
import VideoToolbox
import CoreMedia
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless protocol client. Connects to the host, decodes the HEVC stream and
/// writes a PNG of the first frame, so the capture/encode/transport path can be
/// verified without a phone.
final class Probe {

    struct Options {
        var host: String
        var port: UInt16
        var seconds: Double
        var outputPath: String
        var inputTest: Bool
        var zoom: Double
        var centerX: Double
        var centerY: Double
        var chord: String?
        var token: String
    }

    private let options: Options
    private let queue = DispatchQueue(label: "probe")
    private let finished = DispatchSemaphore(value: 0)
    private var connection: NWConnection?

    private var decoder = FrameDecoder()
    private var format: CMFormatDescription?
    private var decompression: VTDecompressionSession?

    private var framesReceived = 0
    private var framesDecoded = 0
    private var bytesReceived = 0
    private var keyframes = 0
    private var startedAt = Date()
    private var firstFrameAt: Date?
    private var displayInfo: DisplayInfo?
    private var videoConfig: VideoConfig?
    private var savedPNG = false
    private var readyToSave = true
    private var lastError: String?

    init(options: Options) {
        self.options = options
    }

    func run() -> Int32 {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let port = NWEndpoint.Port(rawValue: options.port) else { return 2 }
        let connection = NWConnection(host: NWEndpoint.Host(options.host), port: port, using: params)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("connected to \(self.options.host):\(self.options.port)")
                let hello = Hello(clientName: "probe", token: self.options.token,
                                  maxDimension: 1600, targetFPS: 30)
                self.send(.hello, hello)
                self.receive()
            case .failed(let error):
                print("connection failed: \(error.localizedDescription)")
                self.finish()
            case .waiting(let error):
                print("waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)

        DispatchQueue.global().asyncAfter(deadline: .now() + options.seconds) {
            self.finish()
        }

        _ = finished.wait(timeout: .now() + options.seconds + 20)
        report()
        return savedPNG ? 0 : 3
    }

    private func finish() {
        connection?.cancel()
        finished.signal()
    }

    // MARK: - Sending

    private func send<T: Encodable>(_ type: MessageType, _ value: T) {
        connection?.send(content: Framing.packet(type: type, json: value), completion: .idempotent)
    }

    // MARK: - Receiving

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.bytesReceived += data.count
                self.decoder.append(data)
                while let message = self.decoder.next() {
                    self.handle(message)
                }
            }
            if isComplete || error != nil { self.finish(); return }
            self.receive()
        }
    }

    private func handle(_ message: (type: MessageType, payload: Data)) {
        switch message.type {
        case .displayInfo:
            guard let info = try? JSONDecoder().decode(DisplayInfo.self, from: message.payload) else { return }
            displayInfo = info
            print("display: \(info.pixelWidth)x\(info.pixelHeight) px, \(Int(info.pointWidth))x\(Int(info.pointHeight)) pt")
            if options.inputTest { runInputTest() }
            if let chord = options.chord {
                readyToSave = false
                print("sending chord: \(chord)")
                queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.sendChord(chord) }
                queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.savedPNG = false
                    self?.readyToSave = true
                }
                if chord == "cmd-space" {
                    queue.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                        self?.sendChord("escape")
                    }
                }
            }
            if options.zoom > 1.01 {
                readyToSave = false
                let viewport = Viewport(centerX: options.centerX, centerY: options.centerY, zoom: options.zoom)
                send(.setViewport, viewport)
                print("requested viewport zoom \(options.zoom)x at (\(options.centerX), \(options.centerY))")
            }

        case .videoConfig:
            guard let config = try? JSONDecoder().decode(VideoConfig.self, from: message.payload) else { return }
            videoConfig = config
            print("video config: \(config.codec) \(config.width)x\(config.height), \(config.parameterSets.count) params, nal header \(config.nalUnitHeaderLength)")
            do {
                format = try makeFormatDescription(config)
            } catch {
                print("format description failed: \(error)")
            }

        case .videoFrame:
            framesReceived += 1
            if firstFrameAt == nil { firstFrameAt = Date() }
            decode(message.payload)

        case .viewportState:
            if let applied = try? JSONDecoder().decode(Viewport.self, from: message.payload) {
                let r = applied.rect
                print(String(format: "host applied %.2fx rect (%.3f, %.3f, %.3f, %.3f)", applied.zoom, r.x, r.y, r.w, r.h))
                readyToSave = true
            }

        case .stats:
            if let stats = try? JSONDecoder().decode(HostStats.self, from: message.payload) {
                print(String(format: "host stats: %.1f fps, %.0f kbps, %d client(s)", stats.fps, stats.kbps, stats.clients))
            }

        default:
            break
        }
    }

    // MARK: - Chord test

    private func sendChord(_ name: String) {
        func press(_ modifier: UInt16, _ flag: UInt64, _ code: UInt16) {
            _ = modifier
            send(.input, InputEvent.chord(code: code, flags: flag))
        }
        switch name {
        case "ctrl-up":    press(59, EventFlags.control, 126)
        case "ctrl-left":  press(59, EventFlags.control, 123)
        case "ctrl-left-fn": press(59, EventFlags.control | EventFlags.fn, 123)
        case "ctrl-right": press(59, EventFlags.control, 124)
        case "cmd-m":      press(55, EventFlags.command, 46)
        case "cmd-space":  press(55, EventFlags.command, 49)
        case "toggle-fullscreen": press(55, EventFlags.command | EventFlags.control, 3)
        case "escape":     send(.input, InputEvent.key(code: 53, down: true, flags: 0))
                           send(.input, InputEvent.key(code: 53, down: false, flags: 0))
        default: print("unknown chord \(name)")
        }
    }

    // MARK: - Input test

    private func runInputTest() {
        print("input test: batch A now, batch B in 4s")
        sendBatch(steps: 3)
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            print("input test: batch B (after caffeinate window)")
            self?.sendBatch(steps: 3)
        }
    }

    private func sendBatch(steps: Int) {
        for _ in 0..<steps {
            send(.input, InputEvent.moveRelative(dx: 60, dy: 40))
        }
    }

    // MARK: - Decode

    private func makeFormatDescription(_ config: VideoConfig) throws -> CMFormatDescription {
        let sets = config.parameterSets.compactMap { Data(base64Encoded: $0) }
        guard !sets.isEmpty else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no parameter sets"]) }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var keepAlive: [Data] = sets
        for index in sets.indices {
            keepAlive[index].withUnsafeBytes { raw in
                pointers.append(raw.bindMemory(to: UInt8.self).baseAddress!)
                sizes.append(raw.count)
            }
        }

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw NSError(domain: "probe", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CMVideoFormatDescriptionCreateFromHEVCParameterSets \(status)"])
        }
        withExtendedLifetime(keepAlive) {}
        return description
    }

    private func decode(_ payload: Data) {
        guard let header = VideoFrameHeader.decode(payload), let format else { return }
        if header.flags & VideoFrameHeader.flagsKeyframe != 0 { keyframes += 1 }

        let nal = payload.subdata(in: VideoFrameHeader.byteCount..<payload.count)
        guard !nal.isEmpty else { return }

        if decompression == nil {
            var session: VTDecompressionSession?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                      formatDescription: format,
                                                      decoderSpecification: nil,
                                                      imageBufferAttributes: attrs as CFDictionary,
                                                      outputCallback: nil,
                                                      decompressionSessionOut: &session)
            guard status == noErr, let session else {
                lastError = "VTDecompressionSessionCreate failed: \(status)"
                return
            }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            decompression = session
        }
        guard let decompression else { return }

        var blockBuffer: CMBlockBuffer?
        let st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                    memoryBlock: nil,
                                                    blockLength: nal.count,
                                                    blockAllocator: kCFAllocatorDefault,
                                                    customBlockSource: nil,
                                                    offsetToData: 0,
                                                    dataLength: nal.count,
                                                    flags: 0,
                                                    blockBufferOut: &blockBuffer)
        guard st == kCMBlockBufferNoErr, let blockBuffer else { return }
        let copyStatus = nal.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: nal.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: header.presentationMicros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = nal.count
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                 dataBuffer: blockBuffer,
                                                 formatDescription: format,
                                                 sampleCount: 1,
                                                 sampleTimingEntryCount: 1,
                                                 sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 1,
                                                 sampleSizeArray: &sampleSize,
                                                 sampleBufferOut: &sampleBuffer)
        guard sbStatus == noErr, let sampleBuffer else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(decompression,
                                          sampleBuffer: sampleBuffer,
                                          flags: flags,
                                          infoFlagsOut: &infoFlags) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                if self.lastError == nil { self.lastError = "decode status \(status)" }
                return
            }
            self.framesDecoded += 1
            if self.readyToSave, !self.savedPNG {
                self.savedPNG = true
                self.writePNG(imageBuffer, header: header)
            }
        }
    }

    private func writePNG(_ buffer: CVPixelBuffer, header: VideoFrameHeader) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage() else {
            print("could not build CGImage")
            return
        }
        let url = URL(fileURLWithPath: options.outputPath)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(url.path) (\(width)x\(height), frame #\(header.sequence))")
    }

    // MARK: - Report

    private func report() {
        let elapsed = Date().timeIntervalSince(firstFrameAt ?? startedAt)
        let fps = elapsed > 0 ? Double(framesReceived) / elapsed : 0
        print("---")
        print(String(format: "received %d frames (%d keyframes) in %.1fs = %.1f fps",
                     framesReceived, keyframes, elapsed, fps))
        print("decoded \(framesDecoded) frames, \(bytesReceived / 1024) KiB total, \(videoConfig == nil ? "NO CONFIG" : "config ok")")
        if let lastError { print("last error: \(lastError)") }
        if let displayInfo, let videoConfig {
            print("stream \(videoConfig.width)x\(videoConfig.height) of display \(displayInfo.pixelWidth)x\(displayInfo.pixelHeight)")
        }
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
var host = "127.0.0.1"
var port: UInt16 = ProtocolLimits.defaultPort
var seconds: Double = 6
var output = "/tmp/remotemac-frame.png"
var inputTest = false
var zoom = 1.0
var chord: String? = nil
var token = "" 
var centerX = 0.5
var centerY = 0.5

var index = 1
while index < args.count {
    switch args[index] {
    case "--host": host = args[index + 1]; index += 2
    case "--port": port = UInt16(args[index + 1]) ?? port; index += 2
    case "--seconds": seconds = Double(args[index + 1]) ?? seconds; index += 2
    case "--out": output = args[index + 1]; index += 2
    case "--input": inputTest = true; index += 1
    case "--zoom": zoom = Double(args[index + 1]) ?? 1; index += 2
    case "--chord": chord = args[index + 1]; index += 2
    case "--token": token = args[index + 1]; index += 2
    case "--center":
        let parts = args[index + 1].split(separator: ",")
        if parts.count == 2 {
            centerX = Double(parts[0]) ?? 0.5
            centerY = Double(parts[1]) ?? 0.5
        }
        index += 2
    default: index += 1
    }
}

let probe = Probe(options: .init(host: host, port: port, seconds: seconds, outputPath: output, inputTest: inputTest,
                              zoom: zoom, centerX: centerX, centerY: centerY, chord: chord,
                              token: token))
exit(probe.run())
