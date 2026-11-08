import SwiftUI
import UIKit

/// An invisible text view that summons the iPhone keyboard and forwards what
/// you enter. It has to be a real text view: dictation and languages that
/// compose text work by writing into one and revising what they wrote.
struct KeyboardCapture: UIViewRepresentable {
    let session: RemoteSession
    let isActive: Bool
    /// Changes whenever the Mac's caret may have moved.
    let epoch: Int

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView(frame: .zero, textContainer: nil)
        view.onInsert = { session.insert($0) }
        view.onDelete = { session.deleteBackward() }
        view.onComposing = { session.composing = $0 }
        view.onDismissed = { session.keyboardShown = false }
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        view.startFresh(for: epoch)
        view.wantsKeyboard = isActive
    }
}

final class KeyCaptureUIView: UITextView, UITextViewDelegate {
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onComposing: ((String) -> Void)?
    /// The system took the keyboard away by itself.
    var onDismissed: (() -> Void)?

    var wantsKeyboard = false {
        didSet { syncFirstResponder() }
    }

    /// What the Mac has been sent so far.
    private var sent = ""
    private var seenEpoch = 0
    private let longestBuffer = 400

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        alpha = 0.02
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        keyboardAppearance = .dark
        // What you type should reach the Mac exactly as typed.
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        if #available(iOS 18.0, *) { writingToolsBehavior = .none }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Three fingers belong to the trackpad, not iOS's undo and copy gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Delete has to work on the Mac even when nothing was typed here.
    override func deleteBackward() {
        if text.isEmpty {
            onDelete?()
        } else {
            super.deleteBackward()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        // Unfinished text can still change completely, so it only gets previewed.
        if let marked = markedTextRange {
            onComposing?(text(in: marked) ?? "")
            return
        }
        onComposing?("")
        forwardChanges()
        if text.count > longestBuffer {
            text = ""
            sent = ""
        }
    }

    /// Sends only the difference, so a word dictation revises gets corrected on the Mac too.
    private func forwardChanges() {
        let now = Array(text), before = Array(sent)
        var common = 0
        while common < min(now.count, before.count), now[common] == before[common] { common += 1 }
        sent = text
        for _ in 0..<(before.count - common) { onDelete?() }
        if common < now.count { onInsert?(String(now[common...])) }
    }

    /// The Mac's caret may be somewhere else now, so earlier text can't be edited any more.
    func startFresh(for epoch: Int) {
        guard epoch != seenEpoch else { return }
        seenEpoch = epoch
        guard markedTextRange == nil else { return }
        text = ""
        sent = ""
    }

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
