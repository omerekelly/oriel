import SwiftUI
import UIKit

/// First responder that speaks `UIKeyInput` directly.
///
/// Deliberately not a `UITextField`: a text field keeps its own text storage and
/// routes input through its editing machinery, so overriding `insertText` is
/// unreliable (autocorrect and predictive input can bypass it). A bare view that
/// conforms to `UIKeyInput` receives every keystroke and stores nothing.
final class KeyCaptureView: UIView, UIKeyInput {

    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // UITextInputTraits
    var hasText: Bool { false }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
    var textContentType: UITextContentType?

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        onText?(text)
    }

    func deleteBackward() {
        onDelete?()
    }
}

struct TypingField: UIViewRepresentable {
    let isActive: Bool
    let onText: (String) -> Void
    let onDelete: () -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.backgroundColor = .clear
        view.alpha = 0.02
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onText = onText
        view.onDelete = onDelete
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            }
        } else if !isActive, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }
}
