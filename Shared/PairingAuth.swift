import Foundation
import CryptoKit

/// The handshake facts both ends must agree on.
struct Handshake: Sendable {
    var macKey: Data
    var deviceKey: Data
    var macEphemeral: Data
    var deviceEphemeral: Data
    var commitment: Data
    /// Empty on the Mac until the device reveals it.
    var clientNonce: Data
    var macNonce: Data
}

/// The cryptography behind pairing, in one place so the two ends can't
/// disagree about it. Uses only Apple's CryptoKit.
///
/// The code people compare on first pairing is only as strong as the rule that
/// neither side can pick its randomness after seeing the other's. So the device
/// commits to its nonce and keys in `hello`, and reveals the nonce only after
/// the Mac has fixed its own. An attacker in the middle gets one chance in a
/// million per connection, with no way to search for values that make the
/// two screens agree.
enum PairingAuth {
    static let version: UInt8 = 4
    static let keyLength = 32
    static let nonceLength = 16
    static let commitmentLength = 32
    static let signatureLength = 64
    static let challengeLength = keyLength * 2 + nonceLength + signatureLength
    /// kind + version + key + ephemeral + commitment
    static let helloHeaderLength = 2 + keyLength * 2 + commitmentLength
    /// kind + nonce + signature
    static let proofLength = 1 + nonceLength + signatureLength
    /// kind + counter + tag
    static let sealOverhead = 1 + 4 + 16

    static func makeNonce() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    static func commitment(clientNonce: Data, deviceKey: Data, deviceEphemeral: Data) -> Data {
        var d = Data("orbit-pointer/v4/commit".utf8)
        d.append(clientNonce)
        d.append(deviceKey)
        d.append(deviceEphemeral)
        return Data(SHA256.hash(data: d))
    }

    private static func transcript(_ label: String, _ h: Handshake, includingNonce: Bool) -> Data {
        var d = Data(label.utf8)
        for part in [h.macKey, h.deviceKey, h.macEphemeral, h.deviceEphemeral, h.commitment, h.macNonce] {
            d.append(part)
        }
        if includingNonce { d.append(h.clientNonce) }
        return d
    }

    /// What the Mac signs. It can't cover the client nonce, which isn't revealed yet.
    static func macStatement(_ h: Handshake) -> Data {
        transcript("orbit-pointer/v4/mac", h, includingNonce: false)
    }

    /// What the device signs.
    static func deviceStatement(_ h: Handshake) -> Data {
        transcript("orbit-pointer/v4/dev", h, includingNonce: true)
    }

    /// A six-digit code both screens show the first time, for the person
    /// pairing to compare before either device trusts the other.
    static func code(_ h: Handshake) -> String {
        let digest = SHA256.hash(data: transcript("orbit-pointer/v4/code", h, includingNonce: true))
        let n = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", n % 1_000_000)
    }

    static func isValid(signature: Data, statement: Data, key: Data) -> Bool {
        guard signature.count == signatureLength,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature, for: statement)
    }

    /// The key for this connection's input, from our ephemeral key and theirs.
    static func sessionKey(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, _ h: Handshake) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
              let secret = try? mine.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: h.clientNonce + h.macNonce,
                                              sharedInfo: transcript("orbit-pointer/v4/session", h, includingNonce: true),
                                              outputByteCount: 32)
    }

    private static func nonce(_ counter: UInt32) -> ChaChaPoly.Nonce? {
        var bytes = Data(count: 8)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try? ChaChaPoly.Nonce(data: bytes)
    }

    /// Wraps one input packet. Counters must only ever go up on a connection.
    static func seal(_ input: Data, counter: UInt32, key: SymmetricKey) -> Data? {
        var w = PacketWriter(.sealed)
        w.u32(counter)
        guard let n = nonce(counter),
              let box = try? ChaChaPoly.seal(input, using: key, nonce: n, authenticating: w.data) else { return nil }
        w.bytes(box.ciphertext)
        w.bytes(box.tag)
        return w.data
    }

    /// Opens a sealed packet, or nil if it is forged, damaged or replayed.
    static func open(_ packet: Data, after lastCounter: UInt32?, key: SymmetricKey) -> (input: Data, counter: UInt32)? {
        var r = PacketReader(packet)
        guard r.kind == .sealed, packet.count >= sealOverhead else { return nil }
        r.skipKind()
        guard let counter = r.u32(), lastCounter.map({ counter > $0 }) ?? true, let n = nonce(counter) else { return nil }
        let body = r.restData()
        var header = PacketWriter(.sealed)
        header.u32(counter)
        guard let box = try? ChaChaPoly.SealedBox(nonce: n, ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let input = try? ChaChaPoly.open(box, using: key, authenticating: header.data) else { return nil }
        return (input, counter)
    }
}
