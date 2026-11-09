import CoreGraphics
import Dispatch
import Foundation

/// Turns remote input into real mouse and keyboard events.
///
/// Built to be just another input device beside your real trackpad: it moves
/// the cursor by relative steps from wherever the cursor really is, adds in
/// anything the hardware did meanwhile, and posts nothing while idle.
///
/// `@unchecked Sendable` invariant: every mutable property is read and written
/// only on `queue`. A serial queue rather than an actor because presses and
/// moves must post in exactly the order they arrived, and unstructured tasks
/// don't promise that.
final class InputEngine: @unchecked Sendable {
    struct Settings: Sendable {
        var speed = 1.0
        /// How gradually a movement plays out, as a time constant in seconds. Hides Bluetooth's uneven timing.
        var smoothing = 0.016
        var reverseScroll = false
        var doubleClickInterval = 0.5
        /// Keys that the selected keyboard layout keeps somewhere other than the US position.
        var shortcutKeys: [UInt8: UInt8] = [:]
    }

    /// Marks events we post, so they can be told apart from the real trackpad's.
    static let syntheticTag: Int64 = 0x4F50_5452

    private let queue = DispatchQueue(label: "OrbitPointer.input", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastTick = 0.0

    private var map = DisplayMap(rects: [.zero])
    private var settings = Settings()
    private var enabled = true

    private var pendingX = 0.0
    private var pendingY = 0.0
    private var deltaRemainderX = 0.0
    private var deltaRemainderY = 0.0
    private var hardwareX = 0.0
    private var hardwareY = 0.0
    private var lastPosted: CGPoint?
    private var lastPostTime = 0.0

    private var held: [MouseButton: String] = [:]
    private var leaseTimer: DispatchSourceTimer?
    private var leaseDeadline = 0.0
    private let leaseDuration = 1.5

    private var lastClickTime = 0.0
    private var lastClickPoint = CGPoint.zero
    private var lastClickButton = MouseButton.left
    private var clickCount = 0
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var scrollPhase: CGScrollPhase?
    private var momentumPhase = CGMomentumScrollPhase.none

    // MARK: setup

    func configure(displays: DisplayMap, settings: Settings) {
        queue.async { [self] in
            map = displays
            self.settings = settings
        }
    }

    func setEnabled(_ on: Bool) {
        queue.async { [self] in
            if !on {
                releaseAll { _ in true }
                discardMotion()
                endScrollPhases()
            }
            enabled = on
        }
    }

    /// Lets go of everything before returning, for sleep and quitting.
    func releaseEverythingNow() {
        queue.sync {
            releaseAll { _ in true }
            discardMotion()
            endScrollPhases()
        }
    }

    // MARK: motion

    func move(dx: Double, dy: Double) {
        queue.async { [self] in
            guard enabled else { return }
            pendingX += dx * settings.speed
            pendingY += dy * settings.speed
            guard timer == nil else { return }
            lastTick = CFAbsoluteTimeGetCurrent()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / 240.0, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    /// The real trackpad moved. Reported only for events we didn't post ourselves.
    func noteHardwareMotion(dx: Double, dy: Double) {
        queue.async { [self] in
            guard timer != nil || CFAbsoluteTimeGetCurrent() - lastPostTime < 0.15 else { return }
            hardwareX += dx
            hardwareY += dy
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func discardMotion() {
        pendingX = 0
        pendingY = 0
        stopTimer()
    }

    private func tick() {
        guard enabled else { stopTimer(); return }
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(max(now - lastTick, 0.0005), 0.05)
        lastTick = now

        var stepX = pendingX, stepY = pendingY
        if abs(pendingX) >= 0.1 || abs(pendingY) >= 0.1, settings.smoothing > 0 {
            let k = 1 - exp(-elapsed / settings.smoothing)
            stepX *= k
            stepY *= k
        } else {
            stopTimer()
        }
        pendingX -= stepX
        pendingY -= stepY
        step(dx: stepX, dy: stepY)
    }

    private func step(dx: Double, dy: Double) {
        let base = position()
        let p = map.clamp(CGPoint(x: base.x + dx, y: base.y + dy))
        postMove(to: p, dx: dx, dy: dy)
        lastPosted = p
        lastPostTime = CFAbsoluteTimeGetCurrent()
        hardwareX = 0
        hardwareY = 0
    }

    /// Where the next step starts: our own last position plus whatever the real
    /// trackpad has done since, while we're moving; otherwise the real cursor.
    private func position() -> CGPoint {
        if let lastPosted, CFAbsoluteTimeGetCurrent() - lastPostTime < 0.15 {
            return CGPoint(x: lastPosted.x + hardwareX, y: lastPosted.y + hardwareY)
        }
        return CGEvent(source: nil)?.location ?? lastPosted ?? .zero
    }

    /// Finishes any motion still playing out under the current button state, so
    /// a press or release lands where the cursor actually is and nothing moves after it.
    private func settleMotion() {
        guard pendingX != 0 || pendingY != 0 else { return }
        step(dx: pendingX, dy: pendingY)
        discardMotion()
    }

    private func postMove(to p: CGPoint, dx: Double, dy: Double) {
        let type: CGEventType
        let button: CGMouseButton
        // Counts a button held on the real trackpad too, so its drag isn't broken.
        if held[.left] != nil || CGEventSource.buttonState(.hidSystemState, button: .left) {
            (type, button) = (.leftMouseDragged, .left)
        } else if held[.right] != nil || CGEventSource.buttonState(.hidSystemState, button: .right) {
            (type, button) = (.rightMouseDragged, .right)
        } else {
            (type, button) = (.mouseMoved, .left)
        }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: p, mouseButton: button) else { return }
        // Whole-pixel deltas for apps that read them, carrying the fractions forward.
        deltaRemainderX += dx
        deltaRemainderY += dy
        let wholeX = deltaRemainderX.rounded(), wholeY = deltaRemainderY.rounded()
        deltaRemainderX -= wholeX
        deltaRemainderY -= wholeY
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(wholeX))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(wholeY))
        ev.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        ev.flags = ev.flags.union(hardwareModifiers())
        ev.post(tap: .cghidEventTap)
    }

    /// Modifier keys physically held on the Mac, so they combine with the phone
    /// the way they would with a second input device.
    private func hardwareModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
    }

    // MARK: buttons

    func buttonDown(_ button: MouseButton, startsDrag: Bool, source id: String) {
        queue.async { [self] in
            guard enabled, held[button] == nil else { return }
            settleMotion()
            held[button] = id
            renewLease()
            startLeaseWatch()
            let p = currentPoint()
            if startsDrag {
                // Tap-then-slide follows a click closely, but it's a drag, not a double-click.
                clickCount = 1
                lastClickTime = 0
            } else {
                clickCount = nextClickCount(button, at: p)
            }
            post(button, down: true, at: p, clicks: clickCount)
        }
    }

    func buttonUp(_ button: MouseButton, source id: String) {
        queue.async { [self] in
            guard held[button] == id else { return }
            settleMotion()
            held[button] = nil
            post(button, down: false, at: currentPoint(), clicks: clickCount)
            stopLeaseWatchIfIdle()
        }
    }

    /// The holder is still there. Without these, a held button lets go by itself.
    func keepAlive(source id: String) {
        queue.async { [self] in
            if held.values.contains(id) { renewLease() }
        }
    }

    /// Lets go of anything this device was holding.
    func cancel(source id: String) {
        queue.async { [self] in
            endScrollPhases()
            guard held.values.contains(id) else { return }
            releaseAll { $0 == id }
            discardMotion()
        }
    }

    private func renewLease() {
        leaseDeadline = CFAbsoluteTimeGetCurrent() + leaseDuration
    }

    private func startLeaseWatch() {
        guard leaseTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self, CFAbsoluteTimeGetCurrent() > self.leaseDeadline else { return }
            self.releaseAll { _ in true }
            self.discardMotion()
        }
        leaseTimer = t
        t.resume()
    }

    private func stopLeaseWatchIfIdle() {
        guard held.isEmpty else { return }
        leaseTimer?.cancel()
        leaseTimer = nil
    }

    private func releaseAll(where matches: (String) -> Bool) {
        for (button, owner) in held where matches(owner) {
            held[button] = nil
            post(button, down: false, at: currentPoint(), clicks: clickCount)
        }
        stopLeaseWatchIfIdle()
    }

    private func currentPoint() -> CGPoint {
        map.clamp(position())
    }

    private func nextClickCount(_ button: MouseButton, at p: CGPoint) -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        var count = 1
        if button == lastClickButton, now - lastClickTime < settings.doubleClickInterval,
           hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8 {
            count = min(clickCount + 1, 3)
        }
        lastClickTime = now
        lastClickPoint = p
        lastClickButton = button
        return count
    }

    private func post(_ button: MouseButton, down: Bool, at p: CGPoint, clicks: Int) {
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                               mouseButton: button == .left ? .left : .right) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        ev.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        ev.flags = ev.flags.union(hardwareModifiers())
        ev.post(tap: .cghidEventTap)
    }

    // MARK: scrolling

    func scroll(dx: Double, dy: Double) {
        queue.async { [self] in
            guard enabled else { return }
            let sign = settings.reverseScroll ? -1.0 : 1.0
            scrollRemainderX += dx * sign
            scrollRemainderY += dy * sign
            let x = scrollRemainderX.rounded(), y = scrollRemainderY.rounded()
            guard x != 0 || y != 0 else { return }
            scrollRemainderX -= x
            scrollRemainderY -= y
            // Int32(exactly:) keeps an extreme value from trapping.
            guard let wheelX = Int32(exactly: x), let wheelY = Int32(exactly: y) else { return }
            postScroll(wheelX, wheelY, scroll: scrollPhase, momentum: momentumPhase)
            if scrollPhase == .began { scrollPhase = .changed }
            if momentumPhase == .begin { momentumPhase = .continuous }
        }
    }

    /// Marking where a scroll is in its life is what gives apps a real trackpad's
    /// smooth scrolling, rubber-banding and momentum.
    func scrollSignal(_ signal: ScrollSignal) {
        queue.async { [self] in
            guard enabled else { return }
            switch signal {
            case .fingersBegan:
                scrollPhase = .began
                momentumPhase = .none
            case .fingersEnded:
                if scrollPhase == .changed { postScroll(0, 0, scroll: .ended, momentum: .none) }
                scrollPhase = nil
            case .momentumBegan:
                momentumPhase = .begin
            case .momentumEnded:
                if momentumPhase == .continuous { postScroll(0, 0, scroll: nil, momentum: .end) }
                momentumPhase = .none
            }
        }
    }

    /// A scroll must never be left open, or the app under it keeps waiting for the end.
    private func endScrollPhases() {
        if scrollPhase == .changed { postScroll(0, 0, scroll: .ended, momentum: .none) }
        if momentumPhase == .continuous { postScroll(0, 0, scroll: nil, momentum: .end) }
        scrollPhase = nil
        momentumPhase = .none
    }

    private func postScroll(_ wheelX: Int32, _ wheelY: Int32, scroll: CGScrollPhase?, momentum: CGMomentumScrollPhase) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scroll?.rawValue ?? 0))
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        ev.post(tap: .cghidEventTap)
    }

    // MARK: keyboard

    func type(_ text: String) {
        queue.async { [self] in
            guard enabled else { return }
            for character in text {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    ev.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func key(_ code: UInt8, modifiers: KeyModifiers) {
        queue.async { [self] in
            guard enabled else { return }
            var flags = hardwareModifiers()
            if modifiers.contains(.command) { flags.insert(.maskCommand) }
            if modifiers.contains(.option) { flags.insert(.maskAlternate) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            // Arrow keys carry these flags on a real keyboard, and system shortcuts look for them.
            if (MacKey.left...MacKey.up).contains(code) {
                flags.insert(.maskSecondaryFn)
                flags.insert(.maskNumericPad)
            }
            let isShortcut = !modifiers.isDisjoint(with: [.command, .option, .control])
            let target = isShortcut ? settings.shortcutKeys[code] ?? code : code
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(target), keyDown: down) else { continue }
                ev.flags = flags
                ev.post(tap: .cghidEventTap)
            }
        }
    }
}
