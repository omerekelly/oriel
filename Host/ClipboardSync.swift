import AppKit

/// Watches the Mac pasteboard and mirrors it to the connected client.
///
/// The change count is used as the signal, and applying a remote value updates
/// it immediately, so the two sides cannot echo the same content back and forth.
final class ClipboardSync {

    private let pasteboard = NSPasteboard.general
    private var lastSeen = -1
    private var timer: Timer?

    /// Called on the main thread when the local user copies something new.
    var onLocalCopy: ((ClipboardPayload) -> Void)?

    func start() {
        guard timer == nil else { return }
        lastSeen = pasteboard.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastSeen else { return }
        lastSeen = count
        guard let payload = read() else { return }
        onLocalCopy?(payload)
    }

    private func read() -> ClipboardPayload? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }
        if let png = pasteboard.data(forType: .png) {
            return ClipboardPayload.image(png: png)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            return ClipboardPayload.image(png: png)
        }
        return nil
    }

    /// Writes remote content locally without bouncing it back.
    func apply(_ payload: ClipboardPayload) {
        pasteboard.clearContents()
        switch payload.kind {
        case .text:
            if let text = payload.text, !text.isEmpty {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let data = payload.pngData {
                pasteboard.setData(data, forType: .png)
            }
        }
        lastSeen = pasteboard.changeCount
    }
}
