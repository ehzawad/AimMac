import Foundation
import CoreBluetooth
import CryptoKit
import Observation
import UIKit

/// The iPhone side of the Bluetooth link. Finds Macs running Orbit Pointer,
/// proves who it's talking to and streams input.
@Observable
@MainActor
final class MacLink: NSObject {
    enum State: Equatable {
        case bluetoothOff, searching, connecting, waitingApproval, ready, denied, identityMismatch
    }

    struct FoundMac: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    private(set) var state: State = .searching {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var found: [FoundMac] = []
    private(set) var macName = ""
    private(set) var macPaused = false {
        didSet { if macPaused != oldValue { onChange?() } }
    }
    /// Shown while the Mac is asking whether to allow this device.
    private(set) var pairingCode: String?
    private(set) var hasPairedMac = false

    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var input: CBCharacteristic?
    @ObservationIgnored private var status: CBCharacteristic?
    @ObservationIgnored private var authChar: CBCharacteristic?

    // Handshake packets, sent as they are.
    @ObservationIgnored private var handshakeQueue: [Data] = []
    // Clicks and keys, in order, sealed as they go out. Never dropped: see `enqueue`.
    @ObservationIgnored private var events: [Data] = []
    // Movement is coalesced, so congestion costs precision and not clicks.
    @ObservationIgnored private var pendingMove = (x: 0.0, y: 0.0)
    @ObservationIgnored private var pendingScroll = (x: 0.0, y: 0.0)

    @ObservationIgnored private var infoTimer: Timer?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTimeout: Task<Void, Never>?
    @ObservationIgnored private var connectionFailed = false
    @ObservationIgnored private var rejected = Set<UUID>()

    @ObservationIgnored private let identity = DeviceIdentity.loadOrCreate()
    @ObservationIgnored private var ephemeral = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private var clientNonce = Data()
    @ObservationIgnored private var commitment = Data()
    @ObservationIgnored private var verifiedMacKey: Data?
    @ObservationIgnored private var sessionKey: SymmetricKey?
    @ObservationIgnored private var counter: UInt32 = 0
    @ObservationIgnored private var challengeRead = false

    private var deviceKey: Data { identity.publicKey.rawRepresentation }

    @ObservationIgnored private let defaults = UserDefaults.standard
    private var pairedID: UUID? {
        get { defaults.string(forKey: "pairedMac").flatMap(UUID.init) }
        set {
            defaults.set(newValue?.uuidString, forKey: "pairedMac")
            hasPairedMac = newValue != nil
        }
    }
    private var pairedName: String {
        get { defaults.string(forKey: "pairedMacName") ?? "" }
        set { defaults.set(newValue, forKey: "pairedMacName") }
    }
    /// The key of the Mac this device paired with; nil until the first approval.
    private var pinnedMacKey: Data? {
        get { defaults.data(forKey: "pairedMacKey") }
        set { defaults.set(newValue, forKey: "pairedMacKey") }
    }

    override init() {
        super.init()
        hasPairedMac = pairedID != nil
        central = CBCentralManager(delegate: self, queue: .main)
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: public

    func pair(_ mac: FoundMac) {
        pairedID = mac.id
        pairedName = mac.name
        pinnedMacKey = nil
        rejected.removeAll()
        central.stopScan()
        found = []
        connectPaired()
    }

    func unpair() {
        reconnectTask?.cancel()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetConnection()
        peripheral = nil
        pairedID = nil
        pairedName = ""
        pinnedMacKey = nil
        macName = ""
        rejected.removeAll()
        found = []
        state = .searching
        scan()
    }

    func move(dx: Double, dy: Double) {
        guard isLive else { return }
        pendingMove.x += dx
        pendingMove.y += dy
        flush()
    }

    func scroll(dx: Double, dy: Double) {
        guard isLive else { return }
        pendingScroll.x += dx
        pendingScroll.y += dy
        flush()
    }

    func button(_ button: MouseButton, down: Bool, startsDrag: Bool = false) {
        guard isLive else { return }
        var w = PacketWriter(down ? .down : .up)
        w.u8(button.rawValue)
        if down { w.u8(startsDrag ? 1 : 0) }
        enqueue(w.data)
    }

    func scrollSignal(_ signal: ScrollSignal) {
        guard isLive else { return }
        var w = PacketWriter(.phase)
        w.u8(signal.rawValue)
        enqueue(w.data)
    }

    func keepAlive() {
        guard isLive else { return }
        enqueue(PacketWriter(.alive).data)
    }

    func type(_ text: String) {
        guard isLive else { return }
        let room = max(4, min(120, (peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 0) - PairingAuth.sealOverhead - 1))
        var rest = text
        while !rest.isEmpty {
            var chunk = utf8Prefix(rest, maxBytes: room)
            if chunk.isEmpty {
                // One huge combining sequence: split it between code points rather than overflow the write.
                var used = 0
                let scalars = rest.unicodeScalars.prefix { scalar in
                    used += String(scalar).utf8.count
                    return used <= room
                }
                chunk = String(String.UnicodeScalarView(scalars))
            }
            var w = PacketWriter(.text)
            w.string(chunk, max: Int.max)
            enqueue(w.data)
            rest = String(rest.unicodeScalars.dropFirst(chunk.unicodeScalars.count))
        }
    }

    func key(_ code: UInt8, modifiers: KeyModifiers = []) {
        guard isLive else { return }
        var w = PacketWriter(.key)
        w.u8(code)
        w.u8(modifiers.rawValue)
        enqueue(w.data)
    }

    private var isLive: Bool { state == .ready && !macPaused }

    // MARK: sending

    private func enqueue(_ inner: Data) {
        // Anything from before this event has to arrive before it, so a click
        // lands where the cursor actually got to.
        if let scroll = takeScroll() { events.append(scroll) }
        if let move = takeMove() { events.append(move) }
        events.append(inner)
        // Throwing away a press or release could leave a button held down, so a
        // link this far behind is dropped; the Mac lets go when it disconnects.
        if events.count > 64, let p = peripheral {
            failConnection(p)
            return
        }
        flush()
    }

    private func takeMove() -> Data? {
        guard pendingMove.x != 0 || pendingMove.y != 0 else { return nil }
        var w = PacketWriter(.move)
        w.f32(Float(pendingMove.x))
        w.f32(Float(pendingMove.y))
        pendingMove = (0, 0)
        return w.data
    }

    /// Fractions of a pixel wait here until they add up to something worth sending.
    private func takeScroll() -> Data? {
        guard abs(pendingScroll.x) >= 1 || abs(pendingScroll.y) >= 1 else { return nil }
        var w = PacketWriter(.scroll)
        w.f32(Float(pendingScroll.x))
        w.f32(Float(pendingScroll.y))
        pendingScroll = (0, 0)
        return w.data
    }

    /// Counters are assigned here, at the moment of writing, so they go out in order.
    private func writeSealed(_ inner: Data, to p: CBPeripheral, _ c: CBCharacteristic) {
        guard let sessionKey else { return }
        counter += 1
        guard let packet = PairingAuth.seal(inner, counter: counter, key: sessionKey) else { return }
        p.writeValue(packet, for: c, type: .withoutResponse)
    }

    private func flush() {
        guard let p = peripheral, let c = input, p.state == .connected else { return }
        while !handshakeQueue.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(handshakeQueue.removeFirst(), for: c, type: .withoutResponse)
        }
        guard handshakeQueue.isEmpty, state == .ready else { return }
        while !events.isEmpty && p.canSendWriteWithoutResponse {
            writeSealed(events.removeFirst(), to: p, c)
        }
        guard events.isEmpty, p.canSendWriteWithoutResponse else { return }
        if let scroll = takeScroll() { writeSealed(scroll, to: p, c) }
        guard p.canSendWriteWithoutResponse else { return }
        if let move = takeMove() { writeSealed(move, to: p, c) }
    }

    private func sendHello(on p: CBPeripheral) {
        let limit = p.maximumWriteValueLength(for: .withoutResponse)
        guard limit >= max(PairingAuth.helloHeaderLength, PairingAuth.proofLength) else {
            failConnection(p)
            return
        }
        ephemeral = Curve25519.KeyAgreement.PrivateKey()
        clientNonce = PairingAuth.makeNonce()
        commitment = PairingAuth.commitment(clientNonce: clientNonce, deviceKey: deviceKey,
                                            deviceEphemeral: ephemeral.publicKey.rawRepresentation)
        var w = PacketWriter(.hello)
        w.u8(PairingAuth.version)
        w.bytes(deviceKey)
        w.bytes(ephemeral.publicKey.rawRepresentation)
        w.bytes(commitment)
        w.string(UIDevice.current.name, max: min(60, limit - PairingAuth.helloHeaderLength))
        handshakeQueue.append(w.data)
        queueInfo()
        flush()
        // A handshake that stalls, or approval nobody gives, ends rather than waits forever.
        handshakeTimeout?.cancel()
        handshakeTimeout = Task { [weak self, weak p] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, let p, p === self.peripheral, self.state != .ready else { return }
            self.failConnection(p)
        }
    }

    private func queueInfo() {
        let level = UIDevice.current.batteryLevel
        var w = PacketWriter(.info)
        w.u8(level < 0 ? 255 : UInt8(clamping: Int((level * 100).rounded())))
        w.string(DeviceInfo.model, max: 20)
        handshakeQueue.append(w.data)
    }

    // MARK: connection

    private func scan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [TM.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connectPaired() {
        guard central.state == .poweredOn, let id = pairedID else { return }
        state = .connecting
        if peripheral == nil, !rejected.contains(id),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(known)
        }
        scan()  // also look for it by name, in case its address changed
    }

    private func attach(_ p: CBPeripheral) {
        resetConnection()
        peripheral = p
        p.delegate = self
        // A pending connect never times out: it completes whenever the Mac is back in range.
        central.connect(p, options: nil)
    }

    /// Forgets everything tied to one connection.
    private func resetConnection() {
        input = nil
        status = nil
        authChar = nil
        handshakeQueue.removeAll()
        events.removeAll()
        pendingMove = (0, 0)
        pendingScroll = (0, 0)
        infoTimer?.invalidate()
        infoTimer = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        verifiedMacKey = nil
        sessionKey = nil
        counter = 0
        challengeRead = false
        pairingCode = nil
        macPaused = false
    }

    private func failConnection(_ p: CBPeripheral) {
        connectionFailed = true
        central.cancelPeripheralConnection(p)
    }

    private func scheduleReconnect(after seconds: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.connectPaired()
        }
    }

    /// The Mac's identity is what counts; a name is only a hint for finding it.
    private func namesMatch(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && a.prefix(12) == b.prefix(12)
    }

    private func handleStatus(_ value: Data, from p: CBPeripheral) {
        guard value.count >= 2 else { return }
        let bytes = [UInt8](value)
        macPaused = bytes[1] != 0
        if value.count > 2 { macName = String(decoding: bytes[2...], as: UTF8.self) }
        switch LinkState(rawValue: bytes[0]) ?? .waiting {
        case .waiting:
            if state != .ready { state = .waitingApproval }
        case .challenge:
            guard !challengeRead, let c = authChar else { return }
            challengeRead = true
            p.readValue(for: c)
        case .approved:
            // Only a Mac that has proved who it is can say we're approved.
            guard let macKey = verifiedMacKey else { return }
            pinnedMacKey = macKey
            pairedID = p.identifier
            pairingCode = nil
            handshakeTimeout?.cancel()
            state = .ready
            flush()
        case .denied:
            state = .denied
        }
    }

    private func handleChallenge(_ value: Data, from p: CBPeripheral) {
        var r = PacketReader(value)
        guard value.count == PairingAuth.challengeLength,
              let macKey = r.data(PairingAuth.keyLength),
              let macEphemeral = r.data(PairingAuth.keyLength),
              let macNonce = r.data(PairingAuth.nonceLength),
              let signature = r.data(PairingAuth.signatureLength) else {
            failConnection(p)
            return
        }
        let handshake = Handshake(macKey: macKey, deviceKey: deviceKey,
                                  macEphemeral: macEphemeral,
                                  deviceEphemeral: ephemeral.publicKey.rawRepresentation,
                                  commitment: commitment, clientNonce: clientNonce, macNonce: macNonce)
        guard PairingAuth.isValid(signature: signature, statement: PairingAuth.macStatement(handshake), key: macKey),
              pinnedMacKey == nil || pinnedMacKey == macKey else {
            rejectMac(p)
            return
        }
        guard let proof = try? identity.signature(for: PairingAuth.deviceStatement(handshake)),
              let key = PairingAuth.sessionKey(mine: ephemeral, theirs: macEphemeral, handshake) else {
            failConnection(p)
            return
        }
        verifiedMacKey = macKey
        sessionKey = key
        pairingCode = PairingAuth.code(handshake)
        state = .waitingApproval
        var w = PacketWriter(.proof)
        w.bytes(clientNonce)
        w.bytes(proof)
        handshakeQueue.append(w.data)
        flush()
    }

    /// Something answered as our Mac and couldn't prove it. Hang up and keep looking.
    private func rejectMac(_ p: CBPeripheral) {
        rejected.insert(p.identifier)
        central.cancelPeripheralConnection(p)
        resetConnection()
        peripheral = nil
        state = .identityMismatch
        scan()
    }
}

extension MacLink: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            reconnectTask?.cancel()
            resetConnection()
            peripheral = nil
            state = .bluetoothOff
            return
        }
        if pairedID != nil { connectPaired() } else { state = .searching; scan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "Mac"
        if let id = pairedID {
            guard !rejected.contains(p.identifier) else { return }
            // Macs rotate their Bluetooth address, so the identifier can change.
            // A name match only earns a connection; the handshake decides.
            let same = p.identifier == id || namesMatch(name, pairedName)
            let busy = peripheral?.state == .connected || peripheral?.identifier == p.identifier
            if same && !busy {
                if let old = peripheral { c.cancelPeripheralConnection(old) }
                state = .connecting
                attach(p)
            }
            return
        }
        if let i = found.firstIndex(where: { $0.id == p.identifier }) {
            found[i].rssi = rssi.intValue
        } else {
            found.append(FoundMac(id: p.identifier, name: name, rssi: rssi.intValue))
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else {
            c.cancelPeripheralConnection(p)
            return
        }
        c.stopScan()
        p.discoverServices([TM.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        peripheral = nil
        scheduleReconnect(after: 1.5)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }  // an old, replaced connection
        resetConnection()
        peripheral = nil
        guard pairedID != nil else { return }
        state = .connecting
        scheduleReconnect(after: connectionFailed ? 1.5 : 0.1)
        connectionFailed = false
        scan()
    }
}

extension MacLink: @MainActor CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        // Connected to a Mac that isn't running the app yet: hang up and wait for it.
        guard error == nil, let s = p.services?.first(where: { $0.uuid == TM.service }) else {
            failConnection(p)
            return
        }
        p.discoverCharacteristics([TM.input, TM.status, TM.auth], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p === peripheral else { return }
        let all = s.characteristics ?? []
        input = all.first { $0.uuid == TM.input }
        status = all.first { $0.uuid == TM.status }
        authChar = all.first { $0.uuid == TM.auth }
        guard error == nil, input != nil, authChar != nil, let status else {
            failConnection(p)
            return
        }
        p.setNotifyValue(true, for: status)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard p === peripheral, ch.uuid == TM.status else { return }
        guard error == nil, ch.isNotifying else {
            failConnection(p)
            return
        }
        // Only now can the Mac's answers reach us.
        state = .waitingApproval
        sendHello(on: p)
        infoTimer?.invalidate()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.queueInfo()
                self?.flush()
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard p === peripheral, error == nil, let v = ch.value else { return }
        if ch.uuid == TM.status { handleStatus(v, from: p) }
        if ch.uuid == TM.auth { handleChallenge(v, from: p) }
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard p === peripheral else { return }
        failConnection(p)
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard p === peripheral else { return }
        flush()
    }
}

@MainActor
enum DeviceInfo {
    private static let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let strongHapticGenerator = UIImpactFeedbackGenerator(style: .rigid)
    static func haptic() { hapticGenerator.impactOccurred() }
    static func strongHaptic() { strongHapticGenerator.impactOccurred() }

    /// Hardware identifier such as "iPhone16,2".
    static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
