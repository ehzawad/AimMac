import SwiftUI
import UIKit

private let mint = Color(red: 0.36, green: 0.95, blue: 0.72)
private let panel = Color.white.opacity(0.07)
private let macAppURL = URL(string: "https://github.com/ehzawad/AimMac/releases")!

struct PhoneRoot: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.sceneActive = (phase == .active)
        }
        .onChange(of: session.link.state, initial: true) { _, s in
            // keep the screen on while it's in use
            UIApplication.shared.isIdleTimerDisabled = (s == .ready)
        }
    }

    @ViewBuilder private var content: some View {
        if session.demo {
            RemoteView()
        } else {
            switch session.link.state {
            case .bluetoothOff:
                Notice(icon: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                       text: "Turn on Bluetooth and allow Orbit Pointer to use it in Settings.")
            case .searching where !session.link.hasPairedMac:
                MacPicker()
            case .searching, .connecting:
                Notice(icon: "laptopcomputer", title: "Connecting…",
                       text: "Make sure Orbit Pointer is running on your Mac.", unpair: true)
            case .waitingApproval:
                ApprovalNotice()
            case .denied:
                Notice(icon: "xmark.shield", title: "Not allowed",
                       text: "The Mac declined this iPhone.", unpair: true)
            case .identityMismatch:
                Notice(icon: "exclamationmark.shield", title: "This isn't your Mac",
                       text: "A nearby device answered as your Mac but couldn't prove it. If you reinstalled Orbit Pointer on your Mac, pair it again.",
                       unpair: true)
            case .ready:
                RemoteView()
            }
        }
    }
}

struct ApprovalNotice: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(mint)
                .accessibilityHidden(true)
            Text("Allow on your Mac").font(.title2.bold())
            if let code = session.link.pairingCode {
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                Text("Click Allow on \(session.link.macName.isEmpty ? "your Mac" : session.link.macName) only if it shows this code.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Confirming your Mac…").foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }
}

struct MacPicker: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        // Sideways there may not be room for everything, so it scrolls only then.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Orbit Pointer").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Your iPhone becomes a trackpad and keyboard for your Mac. Pick the Mac to pair with.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                if session.link.found.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for Macs running Orbit Pointer…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                    .background(panel, in: RoundedRectangle(cornerRadius: 16))
                }
                ForEach(session.link.found) { mac in
                    Button { session.link.pair(mac) } label: {
                        HStack {
                            Image(systemName: "laptopcomputer").font(.title3).accessibilityHidden(true)
                            Text(mac.name).font(.headline)
                            Spacer()
                            Text("Pair").bold().foregroundStyle(.black)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(mint, in: Capsule())
                        }
                        .padding()
                        .background(panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pair with \(mac.name)")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("You also need the free Orbit Pointer app on your Mac.")
                    .foregroundStyle(.secondary)
                Link("Get the Mac app", destination: macAppURL)
                    .font(.headline)
                    .tint(mint)
            }

            Spacer()

            Button { session.demo = true } label: {
                Text("Try the trackpad without a Mac")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(panel, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}

struct Notice: View {
    @Environment(RemoteSession.self) private var session
    let icon: String
    let title: String
    let text: String
    var unpair = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(mint)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if unpair {
                Button("Choose another Mac") { session.link.unpair() }.padding(.top, 8)
            }
        }
        .padding(32)
    }
}

/// The whole app: a trackpad, and a button for the keyboard.
struct RemoteView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showSettings = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isLandscape { landscapeLayout } else { portraitLayout }
        }
        .padding(.horizontal, isLandscape ? 8 : 16)
        .padding(.vertical, isLandscape ? 8 : 12)
        // Swipes starting at the screen's edge should move the pointer, not iOS.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
        .background {
            KeyboardCapture(session: session, isActive: session.keyboardShown, epoch: session.typingEpoch)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onDisappear { session.unlockRotation() }
    }

    private var portraitLayout: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                status
                Spacer()
                rotationLockButton
                headerControl
            }
            trackpad
            if session.keyboardShown {
                TypedPreview(text: session.typedPreview + session.composing)
                KeyRow()
            }
            keyboardButton
        }
    }

    /// As much trackpad as the screen allows, with the controls in a slim column.
    private var landscapeLayout: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                trackpad
                    .overlay(alignment: .topLeading) {
                        // Sideways with the keyboard up, there's only room for it on the trackpad.
                        if session.keyboardShown {
                            TypedPreview(text: session.typedPreview + session.composing)
                                .padding(8)
                        } else {
                            status
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }
                VStack(spacing: 8) {
                    // With the keyboard up there's only room for the button that closes it.
                    if !session.keyboardShown {
                        headerControl
                        rotationLockButton
                    }
                    compactKeyboardButton
                }
                .frame(width: 64)
            }
            if session.keyboardShown { KeyRow() }
        }
    }

    private var rotationLockButton: some View {
        Button { session.toggleRotationLock() } label: {
            Image(systemName: session.rotationLocked ? "lock.rotation" : "lock.open.rotation")
                .font(.title3)
                .foregroundStyle(session.rotationLocked ? mint : Color.white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.rotationLocked ? "Unlock rotation" : "Lock rotation")
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(session.link.macPaused ? Color.orange : mint).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(statusText).font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder private var headerControl: some View {
        if session.demo {
            Button("Done") {
                session.keyboardShown = false
                session.endDrag()
                session.demo = false
            }
            .tint(.white)
            .frame(minHeight: 44)
        } else {
            Button {
                session.keyboardShown = false
                session.endDrag()
                showSettings = true
            } label: {
                Image(systemName: "gearshape").font(.title3).frame(minWidth: 44, minHeight: 44)
            }
            .tint(.white)
            .accessibilityLabel("Settings")
        }
    }

    private var statusText: String {
        if session.demo { return "Demo: no Mac connected" }
        let name = session.link.macName.isEmpty ? "Connected" : session.link.macName
        return session.link.macPaused ? "\(name) · paused" : name
    }

    private var trackpad: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return shape
            .fill(session.dragging ? mint.opacity(0.18) : panel)
            .overlay(shape.stroke(session.dragging ? mint : Color.white.opacity(0.12), lineWidth: 1.5))
            .overlay {
                if !session.keyboardShown {
                    VStack(spacing: 6) {
                        Text("One finger moves · tap clicks · tap, then slide to drag")
                        Text("Two fingers scroll or pinch · two-finger tap right-clicks")
                        Text("Three fingers switch Spaces · up for Mission Control")
                        Text("Hold still to look up")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            .overlay { TrackpadSurface(session: session) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(TrackpadAccessibility(session: session))
    }

    private var keyboardLabel: some View {
        Label(session.keyboardShown ? "Hide Keyboard" : "Keyboard",
              systemImage: session.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
            .font(.headline)
    }

    private var keyboardButton: some View {
        Button { session.keyboardShown.toggle() } label: {
            keyboardLabel
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(session.keyboardShown ? mint.opacity(0.18) : panel, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(session.link.macPaused)
    }

    private var compactKeyboardButton: some View {
        Button { session.keyboardShown.toggle() } label: {
            keyboardLabel
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background(session.keyboardShown ? mint.opacity(0.18) : panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(session.link.macPaused)
    }
}

/// What you've typed, so you can catch a typo without reading the Mac from across the room.
struct TypedPreview: View {
    let text: String

    var body: some View {
        Text(text.isEmpty ? "What you type appears here" : text)
            .font(.body.weight(.medium))
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.head)  // the newest letters are the ones to check
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Typed so far")
            .accessibilityValue(text.isEmpty ? "Nothing yet" : text)
    }
}

/// Every trackpad gesture, available through VoiceOver's actions rotor.
struct TrackpadAccessibility: ViewModifier {
    let session: RemoteSession

    func body(content: Content) -> some View {
        let element = content
            .accessibilityElement()
            .accessibilityLabel("Trackpad")
            .accessibilityHint("Touch directly to move and tap to click, or use the actions rotor for click and scroll.")
            .accessibilityAddTraits([.isButton, .allowsDirectInteraction])
        let pointing = element
            .accessibilityAction { session.click(.left) }
            .accessibilityAction(named: "Right click") { session.click(.right) }
            .accessibilityAction(named: "Look up") { session.lookUp() }
        let scrolling = pointing
            .accessibilityAction(named: "Scroll up") { session.link.scroll(dx: 0, dy: 120) }
            .accessibilityAction(named: "Scroll down") { session.link.scroll(dx: 0, dy: -120) }
        return scrolling
            .accessibilityAction(named: "Mission Control") { session.swipe(.up) }
            .accessibilityAction(named: "App Exposé") { session.swipe(.down) }
            .accessibilityAction(named: "Next Space") { session.swipe(.left) }
            .accessibilityAction(named: "Previous Space") { session.swipe(.right) }
    }
}

/// The Mac keys an iPhone keyboard doesn't have. Modifiers apply to the next key.
struct KeyRow: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                action("esc", "Escape", MacKey.escape)
                action("tab", "Tab", MacKey.tab)
                modifier("⌘", "Command", .command)
                modifier("⌥", "Option", .option)
                modifier("⌃", "Control", .control)
                modifier("⇧", "Shift", .shift)
                action("←", "Left arrow", MacKey.left)
                action("↑", "Up arrow", MacKey.up)
                action("↓", "Down arrow", MacKey.down)
                action("→", "Right arrow", MacKey.right)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func action(_ title: String, _ label: String, _ code: UInt8) -> some View {
        Button { session.press(code) } label: { keyLabel(title, on: false) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func modifier(_ title: String, _ label: String, _ modifier: KeyModifiers) -> some View {
        let on = session.modifiers.contains(modifier)
        return Button { session.toggle(modifier) } label: { keyLabel(title, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func keyLabel(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(on ? Color.black : Color.white)
            .frame(minWidth: 44, minHeight: 44)
            .background(on ? mint : panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Paired with", value: session.link.macName.isEmpty ? "—" : session.link.macName)
                    Button("Unpair", role: .destructive) {
                        session.link.unpair()
                        dismiss()
                    }
                }
                Section {
                    Text("Speed, smoothing and scroll direction are set on the Mac, in the Orbit Pointer menu.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
