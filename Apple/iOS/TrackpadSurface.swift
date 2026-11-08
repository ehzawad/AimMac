import SwiftUI
import UIKit

/// A real multi-touch surface. SwiftUI's drag gesture only follows one finger,
/// and a trackpad is all about how many fingers are down.
struct TrackpadSurface: UIViewRepresentable {
    let session: RemoteSession

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        view.onMove = { dx, dy in session.link.move(dx: dx, dy: dy) }
        view.onScroll = { dx, dy in session.link.scroll(dx: dx, dy: dy) }
        view.onScrollSignal = { session.link.scrollSignal($0) }
        view.onClick = { session.click($0) }
        view.onDrag = { $0 ? session.beginDrag() : session.endDrag() }
        view.onSwipe = { session.swipe($0) }
        view.onPinch = { session.pinch(zoomIn: $0) }
        view.onLookUp = { session.lookUp() }
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {}
}

enum TrackpadSwipe {
    case left, right, up, down
}

/// The Mac's trackpad gestures, on glass:
///   one finger moves, a tap clicks, tap-then-slide drags, holding still looks up;
///   two fingers scroll or pinch, and a two-finger tap right-clicks;
///   three or more swipe between Spaces and into Mission Control, and a three-finger tap looks up.
final class TrackpadUIView: UIView {
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onScrollSignal: ((ScrollSignal) -> Void)?
    var onClick: ((MouseButton) -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onSwipe: ((TrackpadSwipe) -> Void)?
    var onPinch: ((Bool) -> Void)?
    var onLookUp: (() -> Void)?

    private let tapDuration: TimeInterval = 0.25
    private let tapTravel: CGFloat = 10
    private let tapThenDragWindow: TimeInterval = 0.22
    private let holdDuration: Duration = .milliseconds(500)
    private let swipeDistance: CGFloat = 45
    private let pinchStep: CGFloat = 1.25
    private let scrollGain = 1.6

    private enum TwoFingerMode { case undecided, scroll, pinch }

    private var active = Set<UITouch>()
    private var startTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval = 0
    private var travel: CGFloat = 0
    private var peakFingers = 0
    private var lastCentroid = CGPoint.zero
    private var startCentroid = CGPoint.zero
    private var lastTapEnd: TimeInterval = -1
    private var tapThenDrag = false
    private var dragging = false
    /// False once a gesture has done something else: it can't turn into a tap as well.
    private var tapEligible = true
    private var holdTask: Task<Void, Never>?

    private var twoFingerMode = TwoFingerMode.undecided
    private var startDistance: CGFloat = 0
    private var pinchBaseline: CGFloat = 0
    private var scrolling = false
    private var swipeFired = false

    private var momentum: CADisplayLink?
    private var velocity = CGVector.zero

    // No three-finger undo or copy gestures from iOS here.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        let first = active.isEmpty
        active.formUnion(touches)
        let now = touches.first?.timestamp ?? 0
        if first {
            startTime = now
            lastMoveTime = now
            travel = 0
            peakFingers = 0
            tapEligible = true
            swipeFired = false
            twoFingerMode = .undecided
            tapThenDrag = now - lastTapEnd < tapThenDragWindow
            if !tapThenDrag { startHold() }
        }
        peakFingers = max(peakFingers, active.count)
        if active.count >= 2 {
            cancelHold()
            tapThenDrag = false
            endDragIfNeeded()
        }
        rebaseFingers()
        if active.count >= 3 { endScrollIfNeeded() }
    }

    /// A finger arriving or leaving moves the centre of the group, which isn't motion.
    private func rebaseFingers() {
        lastCentroid = centroid()
        startCentroid = lastCentroid
        startDistance = fingerDistance()
        pinchBaseline = startDistance
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let time = touches.first?.timestamp ?? lastMoveTime
        if peakFingers == 1, let t = active.first {
            moveOneFinger(t)
        } else if peakFingers == 2, active.count == 2 {
            moveTwoFingers(at: time)
        } else if peakFingers >= 3, active.count >= 3 {
            moveThreeFingers()
        }
    }

    private func moveOneFinger(_ t: UITouch) {
        let now = t.location(in: self), last = t.previousLocation(in: self)
        let dx = now.x - last.x, dy = now.y - last.y
        travel += abs(dx) + abs(dy)
        // Below this it's still a tap with a rolling fingertip, not a move.
        guard travel > 3 else {
            lastMoveTime = t.timestamp
            return
        }
        cancelHold()
        // A fingertip rolls a little during a real tap, but past this it was a move.
        if travel > 6 { tapEligible = false }
        if tapThenDrag, !dragging {
            dragging = true
            tapEligible = false
            onDrag?(true)
        }
        // A little acceleration: slow = precise, fast = far.
        let dt = max(t.timestamp - lastMoveTime, 1.0 / 240.0)
        lastMoveTime = t.timestamp
        let gain = 1.4 + min(Double(hypot(dx, dy)) / dt / 720, 2.2)
        onMove?(Double(dx) * gain, Double(dy) * gain)
    }

    private func moveTwoFingers(at time: TimeInterval) {
        let c = centroid()
        let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
        lastCentroid = c
        travel += abs(dx) + abs(dy)
        let distance = fingerDistance()

        switch twoFingerMode {
        case .undecided:
            let spread = abs(distance - startDistance)
            let shift = hypot(c.x - startCentroid.x, c.y - startCentroid.y)
            lastMoveTime = time
            // A gesture is a tap, a scroll or a pinch, never two of them.
            guard max(spread, shift) >= tapTravel else { return }
            tapEligible = false
            twoFingerMode = spread > shift * 1.5 ? .pinch : .scroll
            if twoFingerMode == .scroll {
                scrolling = true
                onScrollSignal?(.fingersBegan)
            }
        case .pinch:
            guard pinchBaseline > 0 else { return }
            let ratio = distance / pinchBaseline
            if ratio >= pinchStep {
                onPinch?(true)
                pinchBaseline = distance
            } else if ratio <= 1 / pinchStep {
                onPinch?(false)
                pinchBaseline = distance
            }
        case .scroll:
            let sx = Double(dx) * scrollGain, sy = Double(dy) * scrollGain
            onScroll?(sx, sy)
            let dt = max(time - lastMoveTime, 1.0 / 240.0)
            lastMoveTime = time
            velocity = CGVector(dx: sx / dt, dy: sy / dt)
        }
    }

    private func moveThreeFingers() {
        let c = centroid()
        travel += abs(c.x - lastCentroid.x) + abs(c.y - lastCentroid.y)
        lastCentroid = c
        let dx = c.x - startCentroid.x, dy = c.y - startCentroid.y
        guard !swipeFired, max(abs(dx), abs(dy)) >= swipeDistance else { return }
        swipeFired = true
        tapEligible = false
        if abs(dx) > abs(dy) {
            onSwipe?(dx < 0 ? .left : .right)
        } else {
            onSwipe?(dy < 0 ? .up : .down)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else {
            rebaseFingers()
            return
        }
        cancelHold()
        let now = touches.first?.timestamp ?? 0
        if dragging {
            endDragIfNeeded()
        } else if tapEligible, travel < tapTravel, now - startTime < tapDuration {
            switch peakFingers {
            case 1:
                onClick?(.left)
                lastTapEnd = now
            case 2:
                onClick?(.right)
            default:
                onLookUp?()
            }
        }
        let keepsGoing = now - lastMoveTime < 0.08  // the fingers were still moving as they lifted
        let wasScrolling = scrolling
        endScrollIfNeeded()
        if wasScrolling, keepsGoing { startMomentum() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        tapEligible = false
        cancelHold()
        if active.isEmpty {
            endDragIfNeeded()
            endScrollIfNeeded()
        } else {
            rebaseFingers()
        }
    }

    private func endDragIfNeeded() {
        guard dragging else { return }
        dragging = false
        onDrag?(false)
    }

    private func endScrollIfNeeded() {
        guard scrolling else { return }
        scrolling = false
        onScrollSignal?(.fingersEnded)
    }

    private func centroid() -> CGPoint {
        guard !active.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in active {
            let p = t.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(active.count), y: y / CGFloat(active.count))
    }

    private func fingerDistance() -> CGFloat {
        guard active.count == 2 else { return 0 }
        let points = active.map { $0.location(in: self) }
        return hypot(points[0].x - points[1].x, points[0].y - points[1].y)
    }

    // MARK: press and hold

    /// iPhones since the XS can't sense pressure, so holding still stands in for a force click.
    private func startHold() {
        holdTask?.cancel()
        let duration = holdDuration
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.active.count == 1, self.peakFingers == 1, self.tapEligible else { return }
            self.tapEligible = false
            self.onLookUp?()
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }

    // MARK: scroll momentum

    private func startMomentum() {
        guard hypot(velocity.dx, velocity.dy) > 200 else { return }
        onScrollSignal?(.momentumBegan)
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        onScroll?(velocity.dx * dt, velocity.dy * dt)
        let decay = pow(0.05, dt)  // loses 95% of its speed per second
        velocity.dx *= decay
        velocity.dy *= decay
        if hypot(velocity.dx, velocity.dy) < 20 { stopMomentum() }
    }

    private func stopMomentum() {
        if momentum != nil { onScrollSignal?(.momentumEnded) }
        momentum?.invalidate()
        momentum = nil
        velocity = .zero
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopMomentum()
            cancelHold()
            active.removeAll()
            endDragIfNeeded()
            endScrollIfNeeded()
        }
    }
}
