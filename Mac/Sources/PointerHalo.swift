import AppKit

/// A round, iPad-style circle around the pointer while the phone is moving it,
/// so it's easy to find from across the room. It fades away when movement
/// stops, leaving the normal arrow.
///
/// It's a click-through window that follows the cursor, because macOS has no
/// public way for a background app to change the system cursor.
@MainActor
final class PointerHalo: NSObject {
    var isEnabled = true

    private let diameter: CGFloat = 40
    private let idleDelay = 0.3
    private lazy var panel = makePanel()
    private var displayLink: CADisplayLink?
    private var lastMotion = 0.0
    private var visible = false

    private func makePanel() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.alphaValue = 0

        let circle = NSView(frame: frame)
        circle.wantsLayer = true
        // A mid grey with a light edge shows up on both light and dark backgrounds.
        circle.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.45).cgColor
        circle.layer?.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        circle.layer?.borderWidth = 1.5
        circle.layer?.cornerRadius = diameter / 2
        p.contentView = circle
        return p
    }

    /// The phone just moved the pointer.
    func noteMotion() {
        guard isEnabled else { return }
        lastMotion = CFAbsoluteTimeGetCurrent()
        guard !visible else { return }
        visible = true
        followCursor()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
        guard let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        followCursor()
        if !isEnabled || CFAbsoluteTimeGetCurrent() - lastMotion > idleDelay { hide() }
    }

    private func followCursor() {
        let p = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: p.x - diameter / 2, y: p.y - diameter / 2))
    }

    private func hide() {
        displayLink?.invalidate()
        displayLink = nil
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}
