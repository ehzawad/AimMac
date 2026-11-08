import AppKit
import CoreBluetooth
import CryptoKit

enum InputEvent {
    case buttonDown(MouseButton, startsDrag: Bool)
    case buttonUp(MouseButton)
    case scroll(dx: Double, dy: Double)
    case move(dx: Double, dy: Double)
    case text(String)
    case key(code: UInt8, modifiers: KeyModifiers)
    case keepAlive
}

struct Peer {
    let central: CBCentral
    let connection: Int
    var publicKey: Data?
    var handshake: Handshake?
    var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    var sessionKey: SymmetricKey?
    var lastCounter: UInt32?
    var challenge = Data()
    var code = ""
    var name = "Unknown device"
    var model = ""
    var battery: Int?
    var state: LinkState = .waiting
    var lastSeen = CFAbsoluteTimeGetCurrent()

    var key: String { central.identifier.uuidString }
}

@MainActor
protocol ReceiverDelegate: AnyObject {
    /// Ask the user whether a new device may control this Mac.
    func receiver(_ r: Receiver, shouldTrust peer: Peer, decide: @escaping @MainActor (Bool) -> Void)
    /// The device being asked about went away.
    func receiverDismissTrustPrompt(_ r: Receiver)
    func receiver(_ r: Receiver, peer: Peer, event: InputEvent)
    /// This device can no longer send input, so anything it held must be let go.
    func receiver(_ r: Receiver, peerDidLeave key: String)
    func receiverDidChange(_ r: Receiver)
}

/// The Mac side of the Bluetooth link: advertises a service that the iPhone
/// app connects to. Nothing goes over Wi-Fi or a server.
@MainActor
final class Receiver: NSObject, @MainActor CBPeripheralManagerDelegate {
    weak var delegate: ReceiverDelegate?

    private var pm: CBPeripheralManager!
    private var statusChar: CBMutableCharacteristic?
    private var publishRetry: Task<Void, Never>?

    private let identity = MacIdentity.loadOrCreate()
    private var macKey: Data { identity.publicKey.rawRepresentation }

    private var nextConnection = 0
    private var promptQueue: [String] = []
    private var promptingKey: String?
    private var recentDenials: [Data: CFAbsoluteTime] = [:]
    private var strangerHellos: [CFAbsoluteTime] = []

    private(set) var peers: [String: Peer] = [:]
    private(set) var bluetoothOn = false
    var paused = false { didSet { broadcastStatus() } }

    private let defaults = UserDefaults.standard
    private var trusted: Set<String> {
        get { Set(defaults.stringArray(forKey: "trustedDeviceKeys") ?? []) }
        set { defaults.set(Array(newValue), forKey: "trustedDeviceKeys") }
    }

    let macName: String = {
        let n = Host.current().localizedName ?? "Mac"
        return String(n.prefix(24))
    }()

    func start() {
        pm = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// The approved device that sent something most recently.
    var activePeer: Peer? {
        peers.values
            .filter { $0.state == .approved }
            .max { $0.lastSeen < $1.lastSeen }
    }

    var trustedCount: Int { trusted.count }

    func forgetAll() {
        trusted = []
        recentDenials.removeAll()
        clearPrompts()
        for k in peers.keys {
            peers[k]?.state = .denied
            delegate?.receiver(self, peerDidLeave: k)
        }
        broadcastStatus()
        delegate?.receiverDidChange(self)
    }

    // MARK: publishing

    /// Every return to powered-on starts clean: Core Bluetooth may have cleared
    /// the service database while Bluetooth was off.
    private func publishService() {
        publishRetry?.cancel()
        pm.stopAdvertising()
        pm.removeAllServices()
        let input = CBMutableCharacteristic(type: TM.input, properties: [.writeWithoutResponse],
                                            value: nil, permissions: [.writeable])
        let status = CBMutableCharacteristic(type: TM.status, properties: [.read, .notify],
                                             value: nil, permissions: [.readable])
        let auth = CBMutableCharacteristic(type: TM.auth, properties: [.read],
                                           value: nil, permissions: [.readable])
        let service = CBMutableService(type: TM.service, primary: true)
        service.characteristics = [input, status, auth]
        statusChar = status
        pm.add(service)
    }

    private func retryPublish() {
        publishRetry?.cancel()
        publishRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.bluetoothOn else { return }
            self.publishService()
        }
    }

    private func dropAllPeers() {
        clearPrompts()
        let keys = Array(peers.keys)
        peers.removeAll()
        for k in keys { delegate?.receiver(self, peerDidLeave: k) }
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        bluetoothOn = (p.state == .poweredOn)
        if bluetoothOn {
            publishService()
        } else {
            publishRetry?.cancel()
            dropAllPeers()
        }
        delegate?.receiverDidChange(self)
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            NSLog("Orbit Pointer: could not add service: \(error)")
            retryPublish()
            return
        }
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [TM.service],
            CBAdvertisementDataLocalNameKey: String(macName.prefix(12)),
        ])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error {
            NSLog("Orbit Pointer: could not advertise: \(error)")
            retryPublish()
        }
    }

    private func makePeer(_ central: CBCentral) -> Peer {
        nextConnection += 1
        return Peer(central: central, connection: nextConnection)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        let key = central.identifier.uuidString
        if peers[key] == nil { peers[key] = makePeer(central) }
        // Ask for the shortest Bluetooth interval; it's the biggest factor in how smooth motion feels.
        pm.setDesiredConnectionLatency(.low, for: central)
        sendStatus(to: key)
        delegate?.receiverDidChange(self)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        let key = central.identifier.uuidString
        peers.removeValue(forKey: key)
        forgetPrompt(for: key)
        delegate?.receiver(self, peerDidLeave: key)
        delegate?.receiverDidChange(self)
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        broadcastStatus()
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let key = request.central.identifier.uuidString
        let data: Data
        switch request.characteristic.uuid {
        case TM.status: data = statusData(for: key)
        case TM.auth: data = peers[key]?.challenge ?? Data()
        default:
            pm.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= data.count else {
            pm.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        pm.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // A batch is all-or-nothing, and every packet is one whole write.
        guard requests.allSatisfy({ $0.characteristic.uuid == TM.input && $0.offset == 0 && $0.value != nil }) else {
            pm.respond(to: first, withResult: .invalidOffset)
            return
        }
        for r in requests {
            if let v = r.value { handle(central: r.central, data: v) }
        }
        pm.respond(to: first, withResult: .success)
    }

    // MARK: packets

    private func handle(central: CBCentral, data: Data) {
        let key = central.identifier.uuidString
        if peers[key] == nil { peers[key] = makePeer(central) }
        peers[key]?.lastSeen = CFAbsoluteTimeGetCurrent()

        var r = PacketReader(data)
        guard let kind = r.kind else { return }
        r.skipKind()

        switch kind {
        case .hello:
            handleHello(key: key, reader: &r)
        case .proof:
            handleProof(key: key, reader: &r)
        case .info:
            let b = r.u8() ?? 255
            peers[key]?.battery = b == 255 ? nil : Int(min(b, 100))
            let model = r.rest()
            if !model.isEmpty { peers[key]?.model = String(model.prefix(40)) }
            delegate?.receiverDidChange(self)
        case .sealed:
            handleSealed(key: key, packet: data)
        default:
            break  // input only counts inside a sealed packet
        }
    }

    private func handleSealed(key: String, packet: Data) {
        guard let peer = peers[key], peer.state == .approved, let sessionKey = peer.sessionKey,
              let opened = PairingAuth.open(packet, after: peer.lastCounter, key: sessionKey) else { return }
        peers[key]?.lastCounter = opened.counter

        var r = PacketReader(opened.input)
        guard let kind = r.kind else { return }
        r.skipKind()

        let event: InputEvent?
        switch kind {
        case .down:
            if let button = r.u8().flatMap(MouseButton.init(rawValue:)) {
                event = .buttonDown(button, startsDrag: r.u8() == 1)
            } else { event = nil }
        case .up: event = r.u8().flatMap(MouseButton.init(rawValue:)).map(InputEvent.buttonUp)
        case .scroll:
            if let dx = r.f32(), let dy = r.f32(), abs(dx) <= 20_000, abs(dy) <= 20_000 {
                event = .scroll(dx: Double(dx), dy: Double(dy))
            } else { event = nil }
        case .move:
            if let dx = r.f32(), let dy = r.f32(), abs(dx) <= 20_000, abs(dy) <= 20_000 {
                event = .move(dx: Double(dx), dy: Double(dy))
            } else { event = nil }
        case .text:
            // Control characters arrive as `key`; none belong in typed text.
            let text = String(String.UnicodeScalarView(r.rest().unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            event = text.isEmpty ? nil : .text(text)
        case .key:
            if let code = r.u8(), code <= 127, let mods = r.u8() {
                event = .key(code: code, modifiers: KeyModifiers(rawValue: mods))
            } else { event = nil }
        case .alive:
            event = .keepAlive
        default:
            event = nil
        }
        if let event { delegate?.receiver(self, peer: peer, event: event) }
    }

    /// A device says who it is. Each connection gets exactly one chance, so an
    /// identity can't be swapped while a prompt is on screen.
    private func handleHello(key: String, reader r: inout PacketReader) {
        guard peers[key]?.publicKey == nil,
              r.u8() == PairingAuth.version,
              let deviceKey = r.data(PairingAuth.keyLength),
              let deviceEphemeral = r.data(PairingAuth.keyLength),
              let commitment = r.data(PairingAuth.commitmentLength) else { return }

        // Each try at guessing a pairing code costs a whole connection, and these make them scarce.
        if !trusted.contains(deviceKey.base64EncodedString()) {
            let now = CFAbsoluteTimeGetCurrent()
            strangerHellos.removeAll { now - $0 > 60 }
            guard strangerHellos.count < 10 else { return }
            strangerHellos.append(now)
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let macNonce = PairingAuth.makeNonce()
        let handshake = Handshake(macKey: macKey, deviceKey: deviceKey,
                                  macEphemeral: ephemeral.publicKey.rawRepresentation,
                                  deviceEphemeral: deviceEphemeral,
                                  commitment: commitment, clientNonce: Data(), macNonce: macNonce)
        guard let signature = try? identity.signature(for: PairingAuth.macStatement(handshake)) else { return }

        var challenge = macKey
        challenge.append(handshake.macEphemeral)
        challenge.append(macNonce)
        challenge.append(signature)

        let name = r.rest()
        peers[key]?.publicKey = deviceKey
        peers[key]?.handshake = handshake
        peers[key]?.ephemeral = ephemeral
        peers[key]?.challenge = challenge
        if !name.isEmpty { peers[key]?.name = String(name.prefix(40)) }
        peers[key]?.state = .challenge
        sendStatus(to: key)
        delegate?.receiverDidChange(self)
    }

    private func handleProof(key: String, reader r: inout PacketReader) {
        guard let peer = peers[key], peer.state == .challenge,
              let deviceKey = peer.publicKey, var handshake = peer.handshake, let ephemeral = peer.ephemeral,
              let clientNonce = r.data(PairingAuth.nonceLength),
              let signature = r.data(PairingAuth.signatureLength) else { return }

        handshake.clientNonce = clientNonce
        let opensCommitment = PairingAuth.commitment(clientNonce: clientNonce, deviceKey: deviceKey,
                                                     deviceEphemeral: handshake.deviceEphemeral) == handshake.commitment
        guard opensCommitment,
              PairingAuth.isValid(signature: signature, statement: PairingAuth.deviceStatement(handshake), key: deviceKey),
              let sessionKey = PairingAuth.sessionKey(mine: ephemeral, theirs: handshake.deviceEphemeral, handshake) else {
            peers[key]?.state = .denied
            sendStatus(to: key)
            delegate?.receiverDidChange(self)
            return
        }
        peers[key]?.handshake = handshake
        peers[key]?.ephemeral = nil
        peers[key]?.sessionKey = sessionKey
        peers[key]?.code = PairingAuth.code(handshake)

        if trusted.contains(deviceKey.base64EncodedString()) {
            peers[key]?.state = .approved
            sendStatus(to: key)
        } else {
            requestApproval(key, deviceKey: deviceKey)
        }
        delegate?.receiverDidChange(self)
    }

    // MARK: approval

    /// Prompts come one at a time, and a device just declined doesn't get to ask again right away.
    private func requestApproval(_ key: String, deviceKey: Data) {
        let now = CFAbsoluteTimeGetCurrent()
        recentDenials = recentDenials.filter { now - $0.value < 60 }
        guard recentDenials[deviceKey] == nil, promptQueue.count < 3 else {
            peers[key]?.state = .denied
            sendStatus(to: key)
            return
        }
        peers[key]?.state = .waiting
        sendStatus(to: key)
        promptQueue.append(key)
        showNextPrompt()
    }

    private func showNextPrompt() {
        guard promptingKey == nil, !promptQueue.isEmpty else { return }
        let key = promptQueue.removeFirst()
        guard let peer = peers[key], let deviceKey = peer.publicKey else {
            showNextPrompt()
            return
        }
        promptingKey = key
        let connection = peer.connection
        delegate?.receiver(self, shouldTrust: peer) { [weak self] ok in
            guard let self, self.promptingKey == key else { return }
            self.promptingKey = nil
            // The decision only counts for the device and connection it was asked about.
            if self.peers[key]?.connection == connection, self.peers[key]?.publicKey == deviceKey {
                if ok {
                    var t = self.trusted
                    t.insert(deviceKey.base64EncodedString())
                    self.trusted = t
                } else {
                    self.recentDenials[deviceKey] = CFAbsoluteTimeGetCurrent()
                }
                self.peers[key]?.state = ok ? .approved : .denied
                self.sendStatus(to: key)
            }
            self.delegate?.receiverDidChange(self)
            self.showNextPrompt()
        }
    }

    private func forgetPrompt(for key: String) {
        promptQueue.removeAll { $0 == key }
        guard promptingKey == key else { return }
        promptingKey = nil
        delegate?.receiverDismissTrustPrompt(self)
        showNextPrompt()
    }

    private func clearPrompts() {
        promptQueue.removeAll()
        if promptingKey != nil {
            promptingKey = nil
            delegate?.receiverDismissTrustPrompt(self)
        }
    }

    // MARK: status

    private func statusData(for key: String, limit: Int = 512) -> Data {
        var d = Data([peers[key]?.state.rawValue ?? LinkState.waiting.rawValue, paused ? 1 : 0])
        d.append(contentsOf: utf8Prefix(macName, maxBytes: max(0, limit - 2)).utf8)
        return d
    }

    private func sendStatus(to key: String) {
        guard let c = statusChar, let peer = peers[key] else { return }
        let data = statusData(for: key, limit: peer.central.maximumUpdateValueLength)
        _ = pm.updateValue(data, for: c, onSubscribedCentrals: [peer.central])
    }

    private func broadcastStatus() {
        for k in peers.keys { sendStatus(to: k) }
    }
}
