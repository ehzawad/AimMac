import AppKit

/// Everything the panel shows. Filled in by AppDelegate.
struct NotchModel: Equatable {
    enum Status { case noBluetooth, searching, waiting, live, paused }
    var status: Status = .searching
    var deviceName = ""
    var connected = false
    var model = ""
    var battery: Int?
    var macPaused = false
}

/// A black panel that hugs the notch (or the middle of the menu bar on Macs
/// without one). It grows when the pointer hovers over it.
@MainActor
final class NotchPanel {
    var onPause: (() -> Void)?
    var onGame: (() -> Void)?
    var model: () -> NotchModel = { NotchModel() }

    private var panel: NSPanel!
    private var view: NotchView!
    private var timer: Timer?
    private var expanded = false
    private var pinned = false
    private var collapseWork: Task<Void, Never>?

    func show() {
        let v = NotchView(frame: .zero)
        v.owner = self
        view = v
        let p = NSPanel(contentRect: collapsedFrame(), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = v
        p.orderFrontRegardless()
        panel = p

        scheduleTimer()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout(animated: false) }
        }
    }

    /// Quick while open, slow while closed, and nothing is drawn unless something changed.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: expanded ? 0.25 : 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let m = model()
        guard m != view.model else { return }
        view.model = m
        view.needsDisplay = true
    }

    // MARK: geometry

    /// The notched display if there is one, otherwise the primary display.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Height of the menu bar strip (the notch is the same height).
    var barHeight: CGFloat {
        let inset = screen?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : NSStatusBar.system.thickness
    }

    /// Width of the camera notch, 0 if there is none.
    var notchWidth: CGFloat {
        guard let s = screen, s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
        return max(0, r.minX - l.maxX)
    }

    /// What the collapsed strip leaves empty in its middle: the notch, or almost nothing.
    var centerGap: CGFloat { max(notchWidth, 16) }

    private func collapsedFrame() -> NSRect {
        guard let f = screen?.frame else { return .zero }
        let w = centerGap + 80
        return NSRect(x: f.midX - w / 2, y: f.maxY - barHeight, width: w, height: barHeight)
    }

    private func expandedFrame() -> NSRect {
        guard let f = screen?.frame else { return .zero }
        let w: CGFloat = max(380, notchWidth + 200)
        let h: CGFloat = barHeight + 118
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func relayout(animated: Bool) {
        let target = expanded ? expandedFrame() : collapsedFrame()
        // Content appears after growing and disappears before shrinking, so it never overlaps mid-animation.
        let showContent = expanded
        if !showContent { view.expanded = false }
        view.model = model()
        view.needsDisplay = true
        guard animated else {
            panel.setFrame(target, display: true)
            view.expanded = showContent
            view.needsDisplay = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.expanded == showContent else { return }
                self.view.expanded = showContent
                self.view.needsDisplay = true
            }
        })
    }

    // MARK: hover / buttons

    func hoverChanged(inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if !expanded {
                expanded = true
                scheduleTimer()
                relayout(animated: true)
            }
        } else if !pinned {
            collapseWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, self.expanded, !self.pinned else { return }
                self.expanded = false
                self.scheduleTimer()
                self.relayout(animated: true)
            }
        }
    }

    func button(_ name: String) {
        switch name {
        case "pause": onPause?()
        case "game": onGame?()
        case "pin":
            pinned.toggle()
            view.pinned = pinned
            view.needsDisplay = true
        default: break
        }
    }
}

final class NotchView: NSView {
    weak var owner: NotchPanel?
    var model = NotchModel()
    var expanded = false
    var pinned = false
    private var hoverButton: String?
    private var buttons: [(String, NSRect)] = []
    private var symbolCache: [String: NSImage] = [:]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { owner?.hoverChanged(inside: true) }
    override func mouseExited(with event: NSEvent) {
        hoverButton = nil
        owner?.hoverChanged(inside: false)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = buttons.first { $0.1.contains(p) }?.0
        if hit != hoverButton { hoverButton = hit; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = buttons.first(where: { $0.1.contains(p) })?.0 { owner?.button(hit) }
    }

    // MARK: drawing

    private let accent = NSColor(calibratedRed: 0.36, green: 0.95, blue: 0.72, alpha: 1)
    private let amber = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.28, alpha: 1)
    private let dim = NSColor(white: 1, alpha: 0.5)

    private var statusColor: NSColor {
        switch model.status {
        case .live: return accent
        case .paused, .waiting: return amber
        case .searching: return NSColor(white: 1, alpha: 0.35)
        case .noBluetooth: return .systemRed
        }
    }

    private var statusText: String {
        switch model.status {
        case .live: return "LIVE"
        case .paused: return "PAUSED"
        case .waiting: return "CONFIRM"
        case .searching: return "WAITING"
        case .noBluetooth: return "BT OFF"
        }
    }

    /// Tinted symbols are built once, not on every redraw.
    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)"
        if let cached = symbolCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if let image { symbolCache[key] = image }
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius: CGFloat = expanded ? 22 : 12
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: r.minX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX, y: r.minY))
        shape.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        shape.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        shape.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        shape.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        shape.close()
        NSColor.black.setFill()
        shape.fill()

        let barH = owner?.barHeight ?? 32
        drawCollapsedStrip(barH: barH)
        buttons = []
        if expanded { drawExpanded(top: barH) }
    }

    /// Status dot on the left of the notch, battery on the right.
    private func drawCollapsedStrip(barH: CGFloat) {
        let gap = owner?.centerGap ?? 16
        let leftX = (bounds.width - gap) / 2 - 36
        let rightX = (bounds.width + gap) / 2 + 8

        let d: CGFloat = 8
        let dot = NSBezierPath(ovalIn: NSRect(x: leftX + 14, y: barH / 2 - d / 2, width: d, height: d))
        statusColor.setFill()
        dot.fill()
        if model.status == .live {
            statusColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: leftX + 10, y: barH / 2 - 8, width: 16, height: 16)).fill()
        }

        let txt: String
        if let b = model.battery { txt = "\(b)%" } else { txt = model.connected ? "—" : "" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: dim,
        ]
        let s = NSAttributedString(string: txt, attributes: attrs)
        s.draw(at: NSPoint(x: rightX, y: barH / 2 - s.size().height / 2))
    }

    private func drawExpanded(top: CGFloat) {
        let pad: CGFloat = 20
        let y0 = top + 14

        // device line
        let glyph = model.connected ? "iphone" : "dot.radiowaves.left.and.right"
        if let img = symbol(glyph, size: 20, weight: .regular, color: .white) {
            img.draw(in: NSRect(x: pad, y: y0 + 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let title = model.connected ? model.deviceName : "No device connected"
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: pad + 32, y: y0))

        var sub: [String] = []
        if !model.model.isEmpty { sub.append(model.model) }
        if let b = model.battery { sub.append("\(b)% battery") }
        if !model.connected { sub.append("Open Orbit Pointer on your iPhone") }
        NSAttributedString(string: sub.joined(separator: "  ·  "), attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim,
        ]).draw(at: NSPoint(x: pad + 32, y: y0 + 19))

        // status pill
        let pillText = NSAttributedString(string: statusText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: statusColor,
        ])
        let pw = pillText.size().width + 20
        let pill = NSRect(x: bounds.width - pad - pw, y: y0 + 4, width: pw, height: 20)
        statusColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        pillText.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - pillText.size().height / 2))

        // buttons
        let items: [(String, String, String)] = [
            ("pause", model.macPaused ? "play.fill" : "pause.fill", model.macPaused ? "Resume" : "Pause"),
            ("pin", pinned ? "pin.fill" : "pin", pinned ? "Pinned" : "Pin"),
            ("game", "gamecontroller", "Game"),
        ]
        let gap: CGFloat = 8, bh: CGFloat = 34
        let bw = (bounds.width - pad * 2 - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        let by = y0 + 50
        for (i, it) in items.enumerated() {
            let rect = NSRect(x: pad + CGFloat(i) * (bw + gap), y: by, width: bw, height: bh)
            buttons.append((it.0, rect))
            let on = (it.0 == "pin" && pinned) || (it.0 == "pause" && model.macPaused)
            NSColor(white: 1, alpha: hoverButton == it.0 ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            let color = on ? accent : NSColor.white
            let label = NSAttributedString(string: it.2, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color,
            ])
            var x = rect.midX - (label.size().width + 20) / 2
            if let img = symbol(it.1, size: 11, weight: .semibold, color: color) {
                img.draw(in: NSRect(x: x, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += 20
            }
            label.draw(at: NSPoint(x: x, y: rect.midY - label.size().height / 2))
        }
    }
}
