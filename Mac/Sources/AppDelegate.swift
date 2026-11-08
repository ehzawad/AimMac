import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, ReceiverDelegate {
    let engine = InputEngine()
    let receiver = Receiver()
    let defaults = UserDefaults.standard

    var statusItem: NSStatusItem!
    let menu = NSMenu()

    // settings
    let speeds: [Double] = [0.7, 1.0, 1.5]
    let speedNames = ["Slow", "Normal", "Fast"]
    let smoothing: [Double] = [0.008, 0.016, 0.024]
    let smoothingNames = ["Low", "Medium", "High"]

    var speedIdx: Int {
        get { defaults.integer(forKey: "speedIdx") }
        set { defaults.set(newValue, forKey: "speedIdx"); applySettings() }
    }
    var smoothingIdx: Int {
        get { defaults.integer(forKey: "smoothingIdx") }
        set { defaults.set(newValue, forKey: "smoothingIdx"); applySettings() }
    }
    var reverseScroll: Bool {
        get { defaults.bool(forKey: "reverseScroll") }
        set { defaults.set(newValue, forKey: "reverseScroll"); applySettings() }
    }
    var roundPointer: Bool {
        get { defaults.bool(forKey: "roundPointer") }
        set { defaults.set(newValue, forKey: "roundPointer"); applySettings() }
    }
    var paused = false

    private let halo = PointerHalo()
    private var askedForAccessibility = false
    private var trustAlert: NSAlert?
    private var trustDecision: (@MainActor (Bool) -> Void)?

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["speedIdx": 1, "smoothingIdx": 1, "reverseScroll": false, "roundPointer": true])
        if !(0..<speeds.count).contains(speedIdx) { speedIdx = 1 }
        if !(0..<smoothing.count).contains(smoothingIdx) { smoothingIdx = 1 }

        // The literal is the value of kAXTrustedCheckOptionPrompt, a C global Swift 6 won't read safely.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "OrbitPointer"  // keeps the place you drag it to
        statusItem.button?.toolTip = "Orbit Pointer"
        setIcon()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        applySettings()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }

        // The real trackpad moving while the phone does, so the two add up.
        let engine = self.engine
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != InputEngine.syntheticTag else { return }
            engine.noteHardwareMotion(dx: Double(event.deltaX), dy: Double(event.deltaY))
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { _ in
            engine.releaseEverythingNow()
        }

        receiver.delegate = self
        receiver.start()
    }

    func applicationWillTerminate(_ n: Notification) {
        engine.releaseEverythingNow()
    }

    private func applySettings() {
        halo.isEnabled = roundPointer
        engine.configure(displays: DisplayMap.current(), settings: InputEngine.Settings(
            speed: speeds[max(0, min(speeds.count - 1, speedIdx))],
            smoothing: smoothing[max(0, min(smoothing.count - 1, smoothingIdx))],
            reverseScroll: reverseScroll,
            doubleClickInterval: NSEvent.doubleClickInterval))
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = NSMenu()
        settings.autoenablesItems = false
        func item(_ title: String, _ sel: Selector?, on: Bool = false, enabled: Bool = true, in target: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.isEnabled = enabled
            (target ?? menu).addItem(i)
        }
        func choices(_ title: String, _ names: [String], selected: Int, action: Selector) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, name) in names.enumerated() {
                let it = NSMenuItem(title: name, action: action, keyEquivalent: "")
                it.tag = i
                it.target = self
                it.state = i == selected ? .on : .off
                sub.addItem(it)
            }
            parent.submenu = sub
            settings.addItem(parent)
        }

        if let p = receiver.activePeer {
            let battery = p.battery.map { String(format: " · %d%%", $0) } ?? ""
            item(p.name + battery, nil, enabled: false)
        } else {
            item(receiver.bluetoothOn ? "No device connected" : "Bluetooth is off", nil, enabled: false)
        }
        if !AXIsProcessTrusted() {
            item("Accessibility: not granted (click to open)", #selector(openAX))
        }
        menu.addItem(.separator())
        item(paused ? "Resume" : "Pause", #selector(togglePause))
        item("Open at Login", #selector(toggleOpenAtLogin), on: opensAtLogin)

        choices("Speed", speedNames, selected: speedIdx, action: #selector(setSpeed(_:)))
        choices("Smoothing", smoothingNames, selected: smoothingIdx, action: #selector(setSmoothing(_:)))
        item("Reverse scrolling", #selector(toggleReverseScroll), on: reverseScroll, in: settings)
        item("Round pointer while moving", #selector(toggleRoundPointer), on: roundPointer, in: settings)
        settings.addItem(.separator())
        item("Play the target game", #selector(openGame), in: settings)
        item("Forget paired devices (\(receiver.trustedCount))", #selector(forget), enabled: receiver.trustedCount > 0, in: settings)
        let settingsParent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsParent.submenu = settings
        menu.addItem(settingsParent)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Orbit Pointer", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func setIcon() {
        let name: String
        if paused { name = "pause.circle" }
        else if receiver.activePeer != nil { name = "iphone.radiowaves.left.and.right" }
        else { name = "cursorarrow.rays" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Orbit Pointer")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    @objc func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func togglePause() {
        paused.toggle()
        receiver.paused = paused
        engine.setEnabled(!paused)
        setIcon()
    }

    private var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleOpenAtLogin() {
        do {
            if opensAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Orbit Pointer: could not change Open at Login: \(error)")
            NSSound.beep()
        }
    }

    @objc func setSpeed(_ s: NSMenuItem) { speedIdx = s.tag }
    @objc func setSmoothing(_ s: NSMenuItem) { smoothingIdx = s.tag }
    @objc func toggleReverseScroll() { reverseScroll.toggle() }
    @objc func toggleRoundPointer() { roundPointer.toggle() }
    @objc func forget() { receiver.forgetAll() }
    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func openGame() {
        guard let url = Bundle.main.url(forResource: "game", withExtension: "html") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: trust prompt

    /// Not `runModal`: that would stall the main queue, and with it the
    /// Bluetooth callbacks of any device already connected.
    func receiver(_ r: Receiver, shouldTrust peer: Peer, decide: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Allow “\(peer.name)” to control this Mac?"
        alert.informativeText = "It will be able to move the pointer, click and type. Only allow it if it shows the code \(peer.code). You can remove it later from the menu bar."
        let allow = alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Don’t Allow")
        // Return shouldn't approve a device by accident.
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\r"
        allow.target = self
        allow.action = #selector(allowTrust)
        deny.target = self
        deny.action = #selector(denyTrust)
        alert.layout()

        trustAlert = alert
        trustDecision = decide
        alert.window.level = .floating
        alert.window.center()
        NSApp.activate()
        alert.window.makeKeyAndOrderFront(nil)
    }

    func receiverDismissTrustPrompt(_ r: Receiver) {
        trustAlert?.window.orderOut(nil)
        trustAlert = nil
        trustDecision = nil
    }

    @objc private func allowTrust() { finishTrust(true) }
    @objc private func denyTrust() { finishTrust(false) }

    private func finishTrust(_ ok: Bool) {
        let decide = trustDecision
        trustAlert?.window.orderOut(nil)
        trustAlert = nil
        trustDecision = nil
        decide?(ok)
    }

    // MARK: ReceiverDelegate

    /// macOS can let an untrusted app move the pointer while dropping its
    /// clicks and keys, so the first one checks that the permission is there.
    private func askForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !askedForAccessibility else { return }
        askedForAccessibility = true
        openAX()
    }

    func receiver(_ r: Receiver, peer: Peer, event: InputEvent) {
        guard !paused else { return }
        switch event {
        case .buttonDown, .key, .text: askForAccessibilityIfNeeded()
        default: break
        }
        switch event {
        case let .move(dx, dy):
            engine.move(dx: dx, dy: dy)
            halo.noteMotion()
        case let .buttonDown(b, startsDrag): engine.buttonDown(b, startsDrag: startsDrag, source: peer.key)
        case let .buttonUp(b): engine.buttonUp(b, source: peer.key)
        case let .scroll(dx, dy): engine.scroll(dx: dx, dy: dy)
        case let .text(s): engine.type(s)
        case let .key(code, mods): engine.key(code, modifiers: mods)
        case .keepAlive: engine.keepAlive(source: peer.key)
        case let .scrollSignal(signal): engine.scrollSignal(signal)
        }
    }

    func receiver(_ r: Receiver, peerDidLeave key: String) {
        engine.cancel(source: key)
    }

    func receiverDidChange(_ r: Receiver) {
        setIcon()
    }
}
