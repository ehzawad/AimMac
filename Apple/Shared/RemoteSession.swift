import Foundation
import Observation

/// What the trackpad and keyboard screens do, on top of the Bluetooth link.
@Observable
@MainActor
final class RemoteSession {
    let link = MacLink()

    /// Show the trackpad without a Mac, so it can be tried first.
    var demo = false
    var keyboardShown = false {
        didSet {
            if !keyboardShown {
                modifiers = []
                composing = ""
                caretMoved()
            }
        }
    }
    /// False while the app is in the background or interrupted.
    var sceneActive = true {
        didSet {
            guard sceneActive != oldValue, !sceneActive else { return }
            endDrag()
            keyboardShown = false
        }
    }

    /// ⌘ ⌥ ⌃ ⇧ waiting for the next key.
    private(set) var modifiers: KeyModifiers = []
    /// The text typed since the Mac's caret was last somewhere we knew, to read from a distance.
    private(set) var typedPreview = ""
    /// Dictation or composed text that isn't final yet.
    var composing = ""
    /// Goes up whenever the Mac's caret may have moved.
    private(set) var typingEpoch = 0

    private func caretMoved() {
        typedPreview = ""
        composing = ""
        typingEpoch &+= 1
    }
    private(set) var dragging = false
    private(set) var rotationLocked = false
    @ObservationIgnored private var leaseTask: Task<Void, Never>?

    init() {
        link.onChange = { [weak self] in self?.linkChanged() }
    }

    private func linkChanged() {
        if link.state != .ready || link.macPaused {
            endDrag()
            modifiers = []
        }
        // The keyboard only ever opens from its button, so a reconnect mustn't bring it back.
        // While the Mac is paused nothing typed would arrive, so it closes then too.
        if (link.state != .ready || link.macPaused) && !demo { keyboardShown = false }
    }

    // MARK: trackpad

    func click(_ button: MouseButton) {
        DeviceInfo.haptic()
        modifiers = []
        caretMoved()  // a click can put the caret anywhere
        link.button(button, down: true)
        link.button(button, down: false)
    }

    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        DeviceInfo.haptic()
        modifiers = []
        caretMoved()
        link.button(.left, down: true, startsDrag: true)
        // The Mac lets go by itself if these stop, however the phone went away.
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.link.keepAlive()
            }
        }
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        leaseTask?.cancel()
        leaseTask = nil
        link.button(.left, down: false)
    }

    // MARK: rotation

    func toggleRotationLock() {
        rotationLocked.toggle()
        RotationLock.set(locked: rotationLocked)
    }

    /// The lock button only exists on the trackpad, so leaving it can't leave the lock on.
    func unlockRotation() {
        guard rotationLocked else { return }
        toggleRotationLock()
    }

    // MARK: gestures

    // macOS has no public way to post a real swipe or pinch, so these use the
    // shortcuts behind the same system features.

    func swipe(_ direction: TrackpadSwipe) {
        DeviceInfo.haptic()
        switch direction {
        case .left: link.key(MacKey.right, modifiers: .control)   // next Space, as on a Mac trackpad
        case .right: link.key(MacKey.left, modifiers: .control)
        case .up: link.key(MacKey.up, modifiers: .control)        // Mission Control
        case .down: link.key(MacKey.down, modifiers: .control)    // App Exposé
        }
    }

    func pinch(zoomIn: Bool) {
        DeviceInfo.haptic()
        link.key(zoomIn ? MacKey.equals : MacKey.minus, modifiers: .command)
    }

    /// The Mac's force click: look up what's under the pointer.
    func lookUp() {
        DeviceInfo.strongHaptic()
        link.key(MacKey.d, modifiers: [.control, .command])
    }

    // MARK: keyboard

    func toggle(_ modifier: KeyModifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
    }

    func press(_ code: UInt8) {
        let plainDelete = code == MacKey.delete && modifiers.isEmpty
        link.key(code, modifiers: modifiers)
        modifiers = []
        if plainDelete {
            if !typedPreview.isEmpty { typedPreview.removeLast() }
        } else {
            caretMoved()  // return, arrows and shortcuts leave the caret somewhere new
        }
    }

    /// Text from the iPhone keyboard, one insertion at a time.
    func insert(_ text: String) {
        var plain = ""
        func flushPlain() {
            if !plain.isEmpty {
                link.type(plain)
                typedPreview += plain
                if typedPreview.count > 120 { typedPreview.removeFirst(typedPreview.count - 120) }
            }
            plain = ""
        }
        for character in text {
            if character.isNewline {
                flushPlain()
                // Only the preview starts over: dictation can still revise what came before.
                link.key(MacKey.returnKey, modifiers: modifiers)
                modifiers = []
                typedPreview = ""
            } else if !modifiers.subtracting(.shift).isEmpty, let chord = MacKey.chord(for: character) {
                // With ⌘ or friends it's a shortcut, which needs the real key.
                flushPlain()
                link.key(chord.code, modifiers: chord.shift ? modifiers.union(.shift) : modifiers)
                modifiers = []
                caretMoved()
            } else {
                // Shift alone is just typing. A modifier only ever applies to the very next key.
                plain += modifiers == .shift ? character.uppercased() : String(character)
                modifiers = []
            }
        }
        flushPlain()
    }

    func deleteBackward() { press(MacKey.delete) }
}
