import AppKit
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let server = ConnectionServer()
    private let capture = CaptureEngine()
    private let injector = InputInjector()
    private let clipboard = ClipboardSync()
    private let files = FileReceiver()
    private var pairingCode = Pairing.loadOrCreate()
    private var activityToken: NSObjectProtocol?

    private var inputCount = 0
    private var textEventCount = 0
    private var keyEventCount = 0
    private var captureStarting = false
    private var captureRunning = false
    private var lastStatsAt = Date()
    private var lastBytesSent = 0
    private var lastAudioBytes = 0
    private var kbps: Double = 0
    private var audioKbps: Double = 0
    private var lastClientRTT: Double = 0
    private var lastDroppedFrames = 0
    private var lastAdaptAt = Date.distantPast
    private var lastLog = "starting"
    private var startedAt = Date()

    private var localAddress: String {
        let ip = HostInfo.tailscaleIPv4 ?? "127.0.0.1"
        return "\(ip):\(server.port)"
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        wireUp()

        do {
            try server.start()
            log("Server listening on \(localAddress)")
            log("Pairing code: \(Pairing.display(pairingCode))")
        } catch {
            log("Server failed: \(error.localizedDescription)")
            alert("Could not start the Oriel server", error.localizedDescription)
        }

        // Ask for Accessibility up front; without it the stream is view-only.
        if !InputInjector.isTrusted {
            InputInjector.requestTrust()
            log("Accessibility permission not granted yet")
        }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        clipboard.start()
        configureLaunchAtLoginIfNeeded()

        if ProcessInfo.processInfo.environment["REMOTEMAC_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                for line in self.injector.selfTest() { self.log("SELFTEST \(line)") }
                for line in self.injector.modifierStateTest() { self.log("CHORDTEST \(line)") }

                func now() -> String {
                    guard let e = CGEvent(source: nil) else { return "nil" }
                    return "(\(Int(e.location.x)),\(Int(e.location.y)))"
                }
                self.log("SELFTEST handle() start \(now())")
                self.injector.handle(.moveRelative(dx: 100, dy: 0))
                usleep(400_000)
                self.log("SELFTEST handle() after move \(now())")
                self.injector.handle(.moveAbsolute(x: 0.25, y: 0.75))
                usleep(400_000)
                self.log("SELFTEST handle() after abs \(now())")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.stop()
        endActivity()
        server.stop()
    }

    // MARK: - Wiring

    private func wireUp() {
        server.onLog = { [weak self] message in self?.log(message) }
        server.validateToken = { [weak self] token in
            guard let self else { return false }
            return Pairing.matches(token, self.pairingCode)
        }

        injector.debugLog = { [weak self] message in self?.log(message) }

        server.onInput = { [weak self] event in
            guard let self else { return }
            // Temporary diagnostic: confirms the phone's keystrokes arrive.
            if case let .text(string) = event, self.textEventCount < 30 {
                self.textEventCount += 1
                self.log("text event #\(self.textEventCount): \(string)")
            }
            if case let .key(code, down, flags) = event, down, self.keyEventCount < 20 {
                self.keyEventCount += 1
                self.log("key event #\(self.keyEventCount): code=\(code) flags=\(flags)")
            }
            self.injector.handle(event)
        }

        clipboard.onLocalCopy = { [weak self] payload in
            guard let self else { return }
            self.server.broadcast(Framing.packet(type: .clipboard, json: payload))
            self.log("Clipboard sent to client (\(payload.kind.rawValue))")
        }

        files.onLog = { [weak self] message in self?.log(message) }
        server.onFileOffer = { [weak self] offer in self?.files.begin(offer) }
        server.onFileChunk = { [weak self] offset, data in self?.files.append(offset: offset, data: data) }
        server.onFileComplete = { [weak self] _ in self?.files.finish() }

        server.onClipboard = { [weak self] payload in
            guard let self else { return }
            self.clipboard.apply(payload)
            self.log("Clipboard received from client (\(payload.kind.rawValue))")
        }

        server.onSelectDisplay = { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("Switching to display \(id)")
                await self.capture.stop()
                self.captureRunning = false
                await self.ensureCaptureRunning(displayID: id)
            }
        }

        server.onPing = { [weak self] ping in
            guard let self, ping.rttMicros > 0 else { return }
            self.lastClientRTT = Double(ping.rttMicros) / 1000
        }

        server.onViewport = { [weak self] viewport in
            guard let self else { return }
            Task { @MainActor [self] in
                await self.capture.apply(viewport: viewport)
                let applied = self.capture.viewport
                let r = applied.rect
                self.injector.updateViewport(CGRect(x: r.x, y: r.y, width: r.w, height: r.h))
                self.server.broadcast(Framing.packet(type: .viewportState, json: applied))
                self.log(String(format: "Viewport %.2fx at (%.2f, %.2f)", applied.zoom, r.x, r.y))
            }
        }

        server.onPeerReady = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.beginActivity()
                self.server.broadcast(Framing.packet(type: .peers, json: Tailnet.peers()))
                await self.ensureCaptureRunning()
            }
        }

        server.onPeerGone = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                guard self.server.peerCount == 0 else { return }
                self.injector.releaseAll()
                self.endActivity()
                await self.capture.stop()
                self.captureRunning = false
                self.log("No clients left, capture stopped")
            }
        }

        capture.onVideoConfig = { [weak self] config in
            guard let self else { return }
            self.server.broadcast(Framing.packet(type: .videoConfig, json: config))
            self.log("Sent codec config \(config.width)x\(config.height), \(config.parameterSets.count) parameter sets")
        }

        capture.onFrame = { [weak self] frame in
            guard let self else { return }
            var f = frame
            f.sequence = self.nextSequence()
            self.server.broadcast(frame: f)
        }

        capture.onAudioDiagnostic = { [weak self] message in
            self?.log(message)
        }

        capture.onAudioConfig = { [weak self] config in
            guard let self else { return }
            self.server.broadcast(Framing.packet(type: .audioConfig, json: config))
            self.log("Audio config: \(Int(config.sampleRate)) Hz, \(config.channels) ch")
        }

        capture.onAudio = { [weak self] pcm in
            guard let self else { return }
            let stamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
            self.server.broadcast(Framing.packet(type: .audioFrame,
                                                 payload: AudioFrame.encode(micros: stamp, pcm: pcm)))
        }

        capture.onError = { [weak self] message in
            self?.log("Capture error: \(message)")
        }
    }

    private var sequence: UInt32 = 0
    private func nextSequence() -> UInt32 {
        sequence &+= 1
        return sequence
    }

    @MainActor
    private func ensureCaptureRunning(displayID: UInt32? = nil) async {
        guard !captureStarting else { return }
        if captureRunning, let info = capture.displayInfo {
            announce(info)
            return
        }
        captureStarting = true
        defer { captureStarting = false }

        // A sleeping display has no framebuffer to capture: nudge the system
        // awake before asking ScreenCaptureKit for content.
        wakeDisplay()

        do {
            try await capture.start(maxDimension: 1600, fps: 30, displayID: displayID)
            captureRunning = true
            if let info = capture.displayInfo {
                injector.updateDisplay(pointSize: CGSize(width: info.pointWidth, height: info.pointHeight))
                announce(info)
                log("Capture started at \(info.pixelWidth)x\(info.pixelHeight)")
            }
        } catch {
            captureRunning = false
            log("Capture start failed: \(error.localizedDescription)")
            alert("Screen capture could not start", error.localizedDescription)
        }
    }

    private func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "3"]
        try? process.run()
    }

    private func announce(_ info: DisplayInfo) {
        injector.updateViewport(CGRect(x: 0, y: 0, width: 1, height: 1))
        server.broadcast(Framing.packet(type: .displayInfo, json: info))
        server.broadcast(Framing.packet(type: .viewportState, json: Viewport.full))
        server.broadcast(Framing.packet(type: .audioConfig, json: capture.audioConfig))
        server.broadcast(Framing.packet(type: .displays, json: capture.displays))
        if let config = capture.greetNewClient() {
            server.broadcast(Framing.packet(type: .videoConfig, json: config))
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◫"
        statusItem.button?.toolTip = "Oriel host"
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let peers = server.peerCount
        let header = NSMenuItem(title: "Oriel — \(peers == 0 ? "waiting" : "\(peers) connected")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let address = NSMenuItem(title: "Address: \(localAddress)", action: #selector(copyAddress), keyEquivalent: "")
        address.target = self
        menu.addItem(address)

        let pairing = NSMenuItem(title: "Pairing code: \(Pairing.display(pairingCode))",
                                  action: #selector(copyPairingCode), keyEquivalent: "")
        pairing.target = self
        menu.addItem(pairing)

        let resetPairing = NSMenuItem(title: "Reset pairing code…", action: #selector(resetPairingCode), keyEquivalent: "")
        resetPairing.target = self
        menu.addItem(resetPairing)

        if let info = capture.displayInfo {
            let stream = NSMenuItem(title: "Streaming \(info.pixelWidth)×\(info.pixelHeight) @ \(String(format: "%.0f", capture.measuredFPS)) fps", action: nil, keyEquivalent: "")
            stream.isEnabled = false
            menu.addItem(stream)

            let bw = NSMenuItem(title: String(format: "Up: %.1f Mbps", kbps), action: nil, keyEquivalent: "")
            bw.isEnabled = false
            menu.addItem(bw)
        }

        menu.addItem(.separator())

        let axTitle = InputInjector.isTrusted ? "Accessibility: granted ✓" : "Accessibility: NOT granted — click to fix"
        let ax = NSMenuItem(title: axTitle, action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        let screen = NSMenuItem(title: "Open Screen Recording settings…", action: #selector(openScreenRecording), keyEquivalent: "")
        screen.target = self
        menu.addItem(screen)

        let shortcuts = NSMenuItem(title: "Enable Mission Control & space shortcuts…", action: #selector(enableShortcuts), keyEquivalent: "")
        shortcuts.target = self
        menu.addItem(shortcuts)

        let restart = NSMenuItem(title: "Restart screen capture", action: #selector(restartCapture), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let login = NSMenuItem(title: launchAtLoginEnabled ? "Launch at login ✓" : "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let last = NSMenuItem(title: "Last: \(lastLog)", action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Oriel Host", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.title = peers == 0 ? "◫" : "◫ \(peers)"
    }

    private func tick() {
        let sent = server.totalBytesSent
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsAt)
        if elapsed >= 1.0 {
            let delta = max(0, sent - lastBytesSent)
            kbps = Double(delta) * 8 / 1000 / elapsed
            lastBytesSent = sent

            let audioDelta = max(0, capture.audioBytesSent - lastAudioBytes)
            audioKbps = Double(audioDelta) * 8 / 1000 / elapsed
            lastAudioBytes = capture.audioBytesSent

            lastStatsAt = now
            adaptBitrateIfNeeded()

            if let size = capture.displayInfo {
                let stats = HostStats(fps: capture.measuredFPS,
                                      kbps: kbps,
                                      audioKbps: audioKbps,
                                      clients: server.peerCount,
                                      capturedWidth: size.pixelWidth,
                                      capturedHeight: size.pixelHeight)
                server.broadcast(Framing.packet(type: .stats, json: stats))
            }
            rebuildMenu()
        }
    }

    // MARK: - Activity assertion (keeps the display awake while streaming)

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Oriel is streaming the screen to a remote client")
        log("Display sleep suppressed")
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
            log("Display sleep suppression released")
        }
    }

    // MARK: - Adaptive bitrate

    /// Trims the encoder when the client reports high latency or frames are
    /// being dropped for being behind, and recovers when the link is healthy.
    private func adaptBitrateIfNeeded() {
        guard capture.isStreaming else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAdaptAt) > 2 else { return }
        lastAdaptAt = now

        let dropped = server.droppedFrameCount
        let newDrops = dropped - lastDroppedFrames
        lastDroppedFrames = dropped

        let rtt = lastClientRTT
        var target = capture.bitrate

        if rtt > 160 || newDrops > 3 {
            target = Int(Double(target) * 0.72)
        } else if rtt > 0, rtt < 70, newDrops == 0 {
            target = Int(Double(target) * 1.12)
        } else {
            return
        }

        // The ramp multiplies without bound; clamp before applying so the log
        // never reports a rate the encoder is not actually using.
        let clamped = max(1_500_000, min(9_000_000, target))
        guard clamped != capture.bitrate else { return }
        capture.setBitrate(clamped)
        log("bitrate target \(clamped / 1000) kbps (rtt \(Int(rtt)) ms, drops \(newDrops))")
    }

    // MARK: - Launch at login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers as a login item the first time it runs, then leaves the choice
    /// to the user. The entry is visible in System Settings > General > Login
    /// Items, so it can be turned off there too.
    private func configureLaunchAtLoginIfNeeded() {
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
                log("Registered as a login item")
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                log("Removed from login items")
            }
        } catch {
            log("Login item update failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLoginEnabled)
    }

    // MARK: - Actions

    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localAddress, forType: .string)
    }

    @objc private func openAccessibility() {
        InputInjector.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Pairing.display(pairingCode), forType: .string)
    }

    @objc private func resetPairingCode() {
        pairingCode = Pairing.reset()
        log("Pairing code reset to \(Pairing.display(pairingCode))")
        rebuildMenu()
    }

    @objc private func enableShortcuts() {
        InputInjector.enableWindowShortcuts()
        log("Enabled Mission Control and space-switching shortcuts")
    }

    @objc private func restartCapture() {
        Task { @MainActor in
            await capture.stop()
            captureRunning = false
            await ensureCaptureRunning()
        }
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        lastLog = message
        let elapsed = String(format: "%6.1f", Date().timeIntervalSince(startedAt))
        let line = "[\(elapsed)s] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: AppDelegate.logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: AppDelegate.logURL)
            }
        }
    }

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/RemoteMacHost.log")

    private func alert(_ title: String, _ detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

enum HostInfo {
    /// Reads the Tailscale IPv4 address without shelling out on every menu
    /// rebuild: it is stable for the life of the process.
    static let tailscaleIPv4: String? = {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // tailscaled exposes its address on a utun interface; pick the one
            // in the 100.64.0.0/10 CGNAT range that Tailscale uses.
            guard name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(interface.ifa_addr.pointee.sa_len)
            guard getnameinfo(interface.ifa_addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("100.") { address = ip; break }
        }
        return address
    }()
}
