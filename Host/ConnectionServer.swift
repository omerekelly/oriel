import Foundation
import Darwin

/// TCP server that fans the encoded stream out to connected clients and feeds
/// incoming input events back to the host.
///
/// Implemented on raw BSD sockets rather than `NWListener`: on macOS the
/// Network.framework listener accepts the SYN arriving over the Tailscale utun
/// but the SYN-ACK never reaches the peer, so connections stall in SYN_RCVD.
/// An IPv4 socket bound to 0.0.0.0 accepts those connections normally.
final class ConnectionServer {

    struct PeerInfo {
        let id: UUID
        var name: String
        var address: String
    }

    private final class Peer {
        let id = UUID()
        let fd: Int32
        var decoder = FrameDecoder()
        var handshaken = false
        var name = "unknown"
        var address = ""
        var framesSent = 0
        var bytesSent = 0

        var out = Data()
        var outOffset = 0
        var flushScheduled = false
        var closed = false

        var pendingBytes: Int { out.count - outOffset }

        init(fd: Int32) {
            self.fd = fd
        }
    }

    let port: UInt16
    private let queue = DispatchQueue(label: "dev.igho.remotemac.server", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var peers: [Int32: Peer] = [:]
    private var readSources: [Int32: DispatchSourceRead] = [:]

    /// Skip frames once this much video is queued for a single peer, so a slow
    /// radio cannot build a multi-second buffer of stale pictures.
    private let maxPendingBytes = 3 * 1024 * 1024

    /// Returns true when the presented pairing code is acceptable.
    var validateToken: ((String) -> Bool)?
    var onInput: ((InputEvent) -> Void)?
    var onViewport: ((Viewport) -> Void)?
    var onPeerReady: ((PeerInfo) -> Void)?
    var onPeerGone: ((UUID) -> Void)?
    var onLog: ((String) -> Void)?

    init(port: UInt16 = ProtocolLimits.defaultPort) {
        self.port = port
    }

    var peerCount: Int { queue.sync { peers.values.filter(\.handshaken).count } }

    var peerNames: [String] {
        queue.sync { peers.values.filter(\.handshaken).map { "\($0.name) @ \($0.address)" } }
    }

    var totalBytesSent: Int { queue.sync { peers.values.reduce(0) { $0 + $1.bytesSent } } }

    // MARK: - Listening

    func start() throws {
        guard listenFD < 0 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posix("socket") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posix("bind")
            close(fd)
            throw error
        }

        guard listen(fd, 16) == 0 else {
            let error = posix("listen")
            close(fd)
            throw error
        }

        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        listenSource = source

        onLog?("Listening on port \(port)")
    }

    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            for peer in peers.values { closePeer(peer, notify: false) }
            peers.removeAll()
            readSources.removeAll()
        }
    }

    private func acceptPending() {
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }

            if fd < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    onLog?("accept failed: \(String(cString: strerror(errno)))")
                }
                return
            }

            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var nodelay: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let peer = Peer(fd: fd)
            peer.address = Self.hostString(address)
            peers[fd] = peer

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(from: peer) }
            source.resume()
            readSources[fd] = source

            onLog?("Peer connected: \(peer.address)")
        }
    }

    // MARK: - Reading

    private func read(from peer: Peer) {
        guard !peer.closed else { return }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)

        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                recv(peer.fd, raw.baseAddress, raw.count, 0)
            }

            if count > 0 {
                peer.decoder.append(Data(bytes: buffer, count: count))
                while let message = peer.decoder.next() {
                    handle(message, from: peer)
                }
                if peer.decoder.isDesynced {
                    onLog?("Protocol desync, dropping peer")
                    closePeer(peer)
                    return
                }
                // Keep draining until the socket reports it has nothing left.
                if count < buffer.count { return }
                continue
            }

            if count == 0 {
                closePeer(peer)
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            closePeer(peer)
            return
        }
    }

    private func handle(_ message: (type: MessageType, payload: Data), from peer: Peer) {
        switch message.type {
        case .hello:
            guard let hello = try? JSONDecoder().decode(Hello.self, from: message.payload) else { return }
            guard hello.version == ProtocolLimits.version else {
                onLog?("Rejecting peer with protocol version \(hello.version)")
                closePeer(peer)
                return
            }
            if let validateToken, !validateToken(hello.token) {
                onLog?("Rejected peer \(hello.clientName) @ \(peer.address): wrong pairing code")
                closePeer(peer)
                return
            }
            peer.name = hello.clientName
            peer.handshaken = true
            onLog?("Handshake from \(hello.clientName) (max \(hello.maxDimension)px @ \(hello.targetFPS)fps)")
            onPeerReady?(PeerInfo(id: peer.id, name: hello.clientName, address: peer.address))

        case .input:
            do {
                let event = try JSONDecoder().decode(InputEvent.self, from: message.payload)
                onInput?(event)
            } catch {
                onLog?("Bad input payload: \(error.localizedDescription)")
            }

        case .setViewport:
            if let viewport = try? JSONDecoder().decode(Viewport.self, from: message.payload) {
                onViewport?(viewport)
            }

        case .ping:
            send(Framing.packet(type: .ping, payload: message.payload), to: peer)

        default:
            break
        }
    }

    // MARK: - Writing

    private func send(_ data: Data, to peer: Peer) {
        guard !peer.closed else { return }
        peer.out.append(data)
        flush(peer)
    }

    private func flush(_ peer: Peer) {
        guard !peer.closed else { return }

        while peer.outOffset < peer.out.count {
            let sent = peer.out.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.send(peer.fd, base.advanced(by: peer.outOffset), raw.count - peer.outOffset, MSG_DONTWAIT)
            }

            if sent > 0 {
                peer.outOffset += sent
                peer.bytesSent += sent
                continue
            }

            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                // Socket buffer is full: retry shortly rather than blocking the
                // server queue. Frames keep being dropped meanwhile by the
                // backlog check in broadcast(frame:).
                guard !peer.flushScheduled else { return }
                peer.flushScheduled = true
                queue.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
                    peer.flushScheduled = false
                    self?.flush(peer)
                }
                return
            }

            closePeer(peer)
            return
        }

        peer.out.removeAll(keepingCapacity: true)
        peer.outOffset = 0
    }

    func broadcast(_ data: Data) {
        queue.async {
            for peer in self.peers.values where peer.handshaken {
                self.send(data, to: peer)
            }
        }
    }

    func broadcast(frame: EncodedFrame) {
        queue.async {
            var payload = VideoFrameHeader(sequence: frame.sequence,
                                           flags: frame.isKeyframe ? VideoFrameHeader.flagsKeyframe : 0,
                                           presentationMicros: frame.presentationMicros,
                                           gapMillis: frame.gapMillis).encoded()
            payload.append(frame.data)
            let packet = Framing.packet(type: .videoFrame, payload: payload)

            for peer in self.peers.values where peer.handshaken {
                if peer.pendingBytes > self.maxPendingBytes && !frame.isKeyframe { continue }
                peer.framesSent += 1
                self.send(packet, to: peer)
            }
        }
    }

    // MARK: - Teardown

    private func closePeer(_ peer: Peer, notify: Bool = true) {
        guard !peer.closed else { return }
        peer.closed = true

        readSources[peer.fd]?.cancel()
        readSources.removeValue(forKey: peer.fd)
        peers.removeValue(forKey: peer.fd)
        close(peer.fd)

        if notify, peer.handshaken {
            onPeerGone?(peer.id)
        }
        onLog?("Peer disconnected: \(peer.address)")
    }

    // MARK: - Helpers

    private static func hostString(_ address: sockaddr_in) -> String {
        var address = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return result == 0 ? String(cString: host) : "unknown"
    }

    private func posix(_ call: String) -> NSError {
        NSError(domain: "RemoteMac.Server", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(call) failed: \(String(cString: strerror(errno)))"])
    }
}
