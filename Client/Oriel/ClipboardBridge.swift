import UIKit

/// Clipboard bridge for the client.
///
/// Writing the Mac's clipboard to the iPhone is silent. Reading the iPhone's
/// clipboard is not: iOS asks the user to confirm a cross-app paste, so that
/// direction is only ever triggered by an explicit tap.
enum ClipboardBridge {

    static func apply(_ payload: ClipboardPayload) {
        let pasteboard = UIPasteboard.general
        switch payload.kind {
        case .text:
            if let text = payload.text, !text.isEmpty {
                pasteboard.string = text
            }
        case .image:
            if let data = payload.pngData, let image = UIImage(data: data) {
                pasteboard.image = image
            }
        }
    }

    static func current() -> ClipboardPayload? {
        let pasteboard = UIPasteboard.general
        if let text = pasteboard.string, !text.isEmpty {
            return .text(text)
        }
        if let image = pasteboard.image, let png = image.pngData() {
            return ClipboardPayload.image(png: png)
        }
        return nil
    }
}
