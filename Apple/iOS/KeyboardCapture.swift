import SwiftUI
import UIKit

/// An invisible view that summons the iPhone keyboard and forwards every key
/// as it's pressed. A text field would need its contents diffed to know what
/// changed; this gets each insertion and delete directly.
struct KeyboardCapture: UIViewRepresentable {
    let session: RemoteSession
    let isActive: Bool

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.onInsert = { session.insert($0) }
        view.onDelete = { session.deleteBackward() }
        view.onDismissed = { session.keyboardShown = false }
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        view.wantsKeyboard = isActive
    }
}

final class KeyCaptureUIView: UIView, UIKeyInput {
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// The system took the keyboard away by itself.
    var onDismissed: (() -> Void)?

    var wantsKeyboard = false {
        didSet { syncFirstResponder() }
    }

    // What you type should reach the Mac exactly as typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    override var canBecomeFirstResponder: Bool { true }
    // Three fingers belong to the trackpad, not iOS's undo and copy gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // Always "has text", so the delete key still works when nothing was typed here.
    var hasText: Bool { true }
    func insertText(_ text: String) { onInsert?(text) }
    func deleteBackward() { onDelete?() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, wantsKeyboard {
            wantsKeyboard = false
            // Not during UIKit's own update of the responder chain.
            let dismissed = onDismissed
            DispatchQueue.main.async { MainActor.assumeIsolated { dismissed?() } }
        }
        return resigned
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncFirstResponder()
    }

    private func syncFirstResponder() {
        guard window != nil else { return }
        if wantsKeyboard, !isFirstResponder {
            becomeFirstResponder()
        } else if !wantsKeyboard, isFirstResponder {
            _ = resignFirstResponder()
        }
    }
}
