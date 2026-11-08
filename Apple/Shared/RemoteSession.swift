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
        didSet { if !keyboardShown { modifiers = [] } }
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
        if link.state != .ready && !demo { keyboardShown = false }
    }

    // MARK: trackpad

    func click(_ button: MouseButton) {
        DeviceInfo.haptic()
        modifiers = []
        link.button(button, down: true)
        link.button(button, down: false)
    }

    func beginDrag() {
        guard !dragging else { return }
        dragging = true
        DeviceInfo.haptic()
        modifiers = []
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
        link.key(code, modifiers: modifiers)
        modifiers = []
    }

    /// Text from the iPhone keyboard, one insertion at a time.
    func insert(_ text: String) {
        var plain = ""
        func flushPlain() {
            if !plain.isEmpty { link.type(plain) }
            plain = ""
        }
        for character in text {
            if character.isNewline {
                flushPlain()
                press(MacKey.returnKey)
            } else if !modifiers.isEmpty, let chord = MacKey.chord(for: character) {
                // With ⌘ or friends it's a shortcut, which needs the real key.
                flushPlain()
                link.key(chord.code, modifiers: chord.shift ? modifiers.union(.shift) : modifiers)
                modifiers = []
            } else {
                // A modifier only ever applies to the very next key, even one with no shortcut.
                modifiers = []
                plain.append(character)
            }
        }
        flushPlain()
    }

    func deleteBackward() { press(MacKey.delete) }
}
