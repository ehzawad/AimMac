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
        view.onClick = { session.click($0) }
        view.onDrag = { $0 ? session.beginDrag() : session.endDrag() }
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {}
}

/// One finger moves, a tap clicks, tap-then-slide drags.
/// Two fingers scroll, and a two-finger tap right-clicks.
final class TrackpadUIView: UIView {
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onClick: ((MouseButton) -> Void)?
    var onDrag: ((Bool) -> Void)?

    private let tapDuration: TimeInterval = 0.25
    private let tapTravel: CGFloat = 10
    private let tapThenDragWindow: TimeInterval = 0.22
    private let scrollGain = 1.6

    private var active = Set<UITouch>()
    private var startTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval = 0
    private var travel: CGFloat = 0
    private var peakFingers = 0
    private var lastCentroid = CGPoint.zero
    private var lastTapEnd: TimeInterval = -1
    private var tapThenDrag = false
    private var dragging = false
    /// False once a gesture has dragged or been cancelled: it can't turn into a tap.
    private var tapEligible = true

    private var momentum: CADisplayLink?
    private var velocity = CGVector.zero

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
            tapThenDrag = now - lastTapEnd < tapThenDragWindow
        }
        peakFingers = max(peakFingers, active.count)
        if active.count >= 2 {
            tapThenDrag = false
            endDragIfNeeded()
        }
        lastCentroid = centroid()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if peakFingers == 1, let t = active.first {
            moveOneFinger(t)
        } else if active.count >= 2 {
            moveTwoFingers(at: touches.first?.timestamp ?? lastMoveTime)
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
        // A gesture is either a two-finger tap or a scroll, never both.
        guard travel >= tapTravel else {
            lastMoveTime = time
            return
        }
        let sx = Double(dx) * scrollGain, sy = Double(dy) * scrollGain
        onScroll?(sx, sy)
        let dt = max(time - lastMoveTime, 1.0 / 240.0)
        lastMoveTime = time
        velocity = CGVector(dx: sx / dt, dy: sy / dt)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        guard active.isEmpty else {
            lastCentroid = centroid()
            return
        }
        let now = touches.first?.timestamp ?? 0
        if dragging {
            endDragIfNeeded()
        } else if tapEligible, travel < tapTravel, now - startTime < tapDuration {
            if peakFingers >= 2 {
                onClick?(.right)
            } else {
                onClick?(.left)
                lastTapEnd = now
            }
        } else if peakFingers >= 2, now - lastMoveTime < 0.08 {
            startMomentum()  // only if the fingers were still moving as they lifted
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.subtract(touches)
        tapEligible = false
        if active.isEmpty {
            endDragIfNeeded()
        } else {
            lastCentroid = centroid()
        }
    }

    private func endDragIfNeeded() {
        guard dragging else { return }
        dragging = false
        onDrag?(false)
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

    // MARK: scroll momentum

    private func startMomentum() {
        guard hypot(velocity.dx, velocity.dy) > 200 else { return }
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
        momentum?.invalidate()
        momentum = nil
        velocity = .zero
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopMomentum()
            active.removeAll()
            endDragIfNeeded()
        }
    }
}
