import Foundation
import Network
import UIKit
import CoreVideo

/// Owns the TCP connection to the host and turns the byte stream into decoded
/// frames plus host statistics.
@MainActor
final class ClientSession: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var displayInfo: DisplayInfo?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var hostFPS: Double = 0
    @Published private(set) var kbps: Double = 0
    @Published private(set) var latencyMS: Double = 0
    @Published private(set) var clientFPS: Double = 0
    @Published private(set) var resolutionText: String = "—"
    @Published private(set) var viewport: Viewport = .full
    @Published private(set) var audioChunks = 0
    @Published private(set) var peers: [PeerEntry] = ClientSession.loadCachedPeers()

    /// Decoded frames are pushed straight into the UIKit surface.
    let renderer = FrameSink()

    private let builder = SampleBuilder()
    private let audio = AudioPlayer()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "dev.igho.remotemac.client", qos: .userInitiated)
    private var framer = FrameDecoder()
    private var receivedFrames = 0
    private var windowStart = Date()
    private var pingTimer: Timer?
    private var lastPingSent: Date?
    private var pairingCode = ""
    private var connectedAt = Date()
    private var lastViewportSent = Date.distantPast

    init() {
        builder.onSample = { [weak self] sample in
            guard let self else { return }
            self.countFrame()
            self.renderer.present(sample)
        }
    }

    // MARK: - Connect

    func connect(host: String, port: UInt16, token: String) {
        disconnect()
        pairingCode = token
        state = .connecting
        displayInfo = nil
        videoSize = .zero
        framer = FrameDecoder()
        receivedFrames = 0
        windowStart = Date()
        viewport = .full
        audioChunks = 0
        lastViewportSent = .distantPast

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Invalid port")
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.connectedAt = Date()
                    self.sendHello()
                    self.startPing()
                    self.receive()
                case .failed(let error):
                    self.state = .failed(Self.describe(error))
                case .waiting(let error):
                    // Tailscale may still be bringing the tunnel up.
                    self.state = .connecting
                    _ = error
                case .cancelled:
                    if self.state == .connected { self.state = .idle }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        builder.reset()
        audio.stop()
        if state == .connected || state == .connecting { state = .idle }
    }

    // MARK: - Receiving

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.async {
                    self.framer.append(data)
                    var messages: [(MessageType, Data)] = []
                    while let message = self.framer.next() { messages.append(message) }
                    if !messages.isEmpty {
                        Task { @MainActor in
                            for message in messages { self.handle(type: message.0, payload: message.1) }
                        }
                    }
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    if case .failed = self.state { return }
                    if let error {
                        self.state = .failed(Self.describe(error))
                    } else if Date().timeIntervalSince(self.connectedAt) < 2.5 {
                        // The host closes immediately when the pairing code is
                        // wrong, so a very short session is almost always that.
                        self.state = .failed("The Mac rejected the connection. Check the pairing code.")
                    } else {
                        self.state = .idle
                    }
                }
                return
            }
            self.receive()
        }
    }

    private func handle(type: MessageType, payload: Data) {
        switch type {
        case .displayInfo:
            guard let info = try? JSONDecoder().decode(DisplayInfo.self, from: payload) else { return }
            displayInfo = info

        case .videoConfig:
            guard let config = try? JSONDecoder().decode(VideoConfig.self, from: payload) else { return }
            do {
                try builder.configure(config)
                videoSize = CGSize(width: config.width, height: config.height)
                resolutionText = "\(config.width)×\(config.height)"
            } catch {
                state = .failed("Decoder setup failed: \(error.localizedDescription)")
            }

        case .videoFrame:
            builder.feed(payload)

        case .audioConfig:
            if let config = try? JSONDecoder().decode(AudioConfig.self, from: payload) {
                audio.start(with: config)
            }

        case .clipboard:
            if let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: payload) {
                ClipboardBridge.apply(payload)
            }

        case .peers:
            if let list = try? JSONDecoder().decode([PeerEntry].self, from: payload) {
                peers = list
                ClientSession.cachePeers(list)
            }

        case .audioFrame:
            audioChunks += 1
            audio.enqueue(AudioFrame.pcm(from: payload))

        case .viewportState:
            if let applied = try? JSONDecoder().decode(Viewport.self, from: payload) {
                viewport = applied
            }

        case .stats:
            if let stats = try? JSONDecoder().decode(HostStats.self, from: payload) {
                hostFPS = stats.fps
                kbps = stats.kbps
            }

        case .ping:
            if let ping = try? JSONDecoder().decode(PingMessage.self, from: payload), !ping.echo {
                var pong = ping
                pong.echo = true
                send(.ping, pong)
            } else if let ping = try? JSONDecoder().decode(PingMessage.self, from: payload), ping.echo, let sent = lastPingSent {
                latencyMS = Date().timeIntervalSince(sent) * 1000
            }

        default:
            break
        }
    }

    private func countFrame() {
        receivedFrames += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            clientFPS = Double(receivedFrames) / elapsed
            receivedFrames = 0
            windowStart = Date()
        }
    }

    // MARK: - Sending

    private func sendHello() {
        var hostName = "iPhone"
        #if canImport(UIKit)
        hostName = UIDevice.current.name
        #endif
        send(.hello, Hello(clientName: hostName,
                           token: pairingCode,
                           maxDimension: 1600,
                           targetFPS: 30))
    }

    func sendInput(_ event: InputEvent) {
        send(.input, event)
    }

    /// User-initiated: reads the iPhone pasteboard and mirrors it to the Mac.
    @discardableResult
    func sendClipboard() -> Bool {
        guard let payload = ClipboardBridge.current() else { return false }
        send(.clipboard, payload)
        return true
    }

    static func cachePeers(_ peers: [PeerEntry]) {
        guard let data = try? JSONEncoder().encode(peers) else { return }
        UserDefaults.standard.set(data, forKey: "knownPeers")
    }

    static func loadCachedPeers() -> [PeerEntry] {
        guard let data = UserDefaults.standard.data(forKey: "knownPeers"),
              let peers = try? JSONDecoder().decode([PeerEntry].self, from: data) else {
            return []
        }
        return peers
    }

    /// Applies a zoom/crop locally and asks the host to capture just that region.
    /// Throttled so a pinch does not flood the link with reconfigurations.
    func setViewport(_ proposed: Viewport, immediate: Bool = false) {
        let clamped = proposed.clamped
        let previous = viewport
        viewport = clamped

        // Ignore the noise from a two-finger scroll: a pinch that barely moved
        // must not reconfigure the host's capture.
        let zoomChanged = abs(clamped.zoom - previous.zoom) > 0.02
        let movedChanged = abs(clamped.centerX - previous.centerX) + abs(clamped.centerY - previous.centerY) > 0.01
        guard immediate || zoomChanged || movedChanged else { return }

        let now = Date()
        guard immediate || now.timeIntervalSince(lastViewportSent) > 0.08 else { return }
        lastViewportSent = now
        send(.setViewport, clamped)
    }

    func resetViewport() {
        setViewport(.full, immediate: true)
    }

    private func send<T: Encodable>(_ type: MessageType, _ value: T) {
        guard let connection else { return }
        let data = Framing.packet(type: type, json: value)
        connection.send(content: data, completion: .idempotent)
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lastPingSent = Date()
            self.send(.ping, PingMessage(sentAtMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
                                         echo: false,
                                         rttMicros: Int64(self.latencyMS * 1000)))
        }
    }

    // MARK: - Helpers

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "Connection refused — is the Mac host running?"
        case .posix(let code) where code == .ETIMEDOUT:
            return "Timed out — check Tailscale on both devices."
        case .dns:
            return "Host not found."
        default:
            return error.localizedDescription
        }
    }
}
