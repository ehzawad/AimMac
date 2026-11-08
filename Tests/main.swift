// Checks the logic that doesn't need a device: packets, pairing, encryption and geometry.
// Run with Tests/run.sh.

import Foundation
import CryptoKit
import CoreGraphics

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "ok  " : "FAIL") \(name)")
    if !condition { failures += 1 }
}

// A full handshake, as each end computes it.
let macIdentity = Curve25519.Signing.PrivateKey()
let deviceIdentity = Curve25519.Signing.PrivateKey()
let macEphemeral = Curve25519.KeyAgreement.PrivateKey()
let deviceEphemeral = Curve25519.KeyAgreement.PrivateKey()
let revealedNonce = PairingAuth.makeNonce()
let handshake = Handshake(macKey: macIdentity.publicKey.rawRepresentation,
                          deviceKey: deviceIdentity.publicKey.rawRepresentation,
                          macEphemeral: macEphemeral.publicKey.rawRepresentation,
                          deviceEphemeral: deviceEphemeral.publicKey.rawRepresentation,
                          commitment: PairingAuth.commitment(clientNonce: revealedNonce,
                                                             deviceKey: deviceIdentity.publicKey.rawRepresentation,
                                                             deviceEphemeral: deviceEphemeral.publicKey.rawRepresentation),
                          clientNonce: revealedNonce,
                          macNonce: PairingAuth.makeNonce())

// The commitment
check(handshake.commitment.count == PairingAuth.commitmentLength, "commitments are the documented length")
check(PairingAuth.commitment(clientNonce: PairingAuth.makeNonce(), deviceKey: handshake.deviceKey,
                             deviceEphemeral: handshake.deviceEphemeral) != handshake.commitment,
      "a different nonce can't open the commitment")
check(PairingAuth.commitment(clientNonce: revealedNonce, deviceKey: handshake.macKey,
                             deviceEphemeral: handshake.deviceEphemeral) != handshake.commitment,
      "a different device key can't open the commitment")
var beforeReveal = handshake
beforeReveal.clientNonce = Data()
check(PairingAuth.macStatement(beforeReveal) == PairingAuth.macStatement(handshake),
      "the Mac signs without needing the unrevealed nonce")
check(PairingAuth.code(beforeReveal) != PairingAuth.code(handshake),
      "the pairing code depends on the revealed nonce")
var otherReveal = handshake
otherReveal.clientNonce = PairingAuth.makeNonce()
let deviceSig = try! deviceIdentity.signature(for: PairingAuth.deviceStatement(handshake))
check(PairingAuth.isValid(signature: deviceSig, statement: PairingAuth.deviceStatement(handshake), key: handshake.deviceKey),
      "a real device signature verifies")
check(!PairingAuth.isValid(signature: deviceSig, statement: PairingAuth.deviceStatement(otherReveal), key: handshake.deviceKey),
      "a device signature doesn't carry over to another nonce")

check(handshake.clientNonce.count == PairingAuth.nonceLength, "nonces are the documented length")
check(handshake.clientNonce != handshake.macNonce, "nonces differ")

// Signatures
let macSig = try! macIdentity.signature(for: PairingAuth.macStatement(handshake))
check(macSig.count == PairingAuth.signatureLength, "signatures are the documented length")
check(PairingAuth.isValid(signature: macSig, statement: PairingAuth.macStatement(handshake), key: handshake.macKey),
      "a real Mac signature verifies")
var altered = handshake
altered.macNonce = PairingAuth.makeNonce()
check(!PairingAuth.isValid(signature: macSig, statement: PairingAuth.macStatement(altered), key: handshake.macKey),
      "a signature from another handshake is rejected")
check(!PairingAuth.isValid(signature: macSig, statement: PairingAuth.macStatement(handshake), key: handshake.deviceKey),
      "a signature under the wrong key is rejected")
check(!PairingAuth.isValid(signature: macSig, statement: PairingAuth.deviceStatement(handshake), key: handshake.macKey),
      "a Mac signature can't stand in for a device signature")
var swappedEphemeral = handshake
swappedEphemeral.deviceEphemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
check(!PairingAuth.isValid(signature: macSig, statement: PairingAuth.macStatement(swappedEphemeral), key: handshake.macKey),
      "swapping an ephemeral key breaks the signature")

// Session key and sealing
let macSide = PairingAuth.sessionKey(mine: macEphemeral, theirs: handshake.deviceEphemeral, handshake)!
let deviceSide = PairingAuth.sessionKey(mine: deviceEphemeral, theirs: handshake.macEphemeral, handshake)!
check(macSide == deviceSide, "both ends derive the same session key")

var input = PacketWriter(.move)
input.f32(12.5)
input.f32(-3)
let sealed = PairingAuth.seal(input.data, counter: 7, key: deviceSide)!
check(sealed.count == input.data.count + PairingAuth.sealOverhead, "sealing adds exactly the documented overhead")
check(sealed.range(of: input.data) == nil, "the input isn't visible in the packet")

let opened = PairingAuth.open(sealed, after: 6, key: macSide)
check(opened?.input == input.data && opened?.counter == 7, "a sealed packet opens on the other end")
check(PairingAuth.open(sealed, after: 7, key: macSide) == nil, "a replayed packet is rejected")
check(PairingAuth.open(sealed, after: 100, key: macSide) == nil, "an old packet is rejected")
check(PairingAuth.open(sealed, after: nil, key: SymmetricKey(size: .bits256)) == nil, "the wrong key is rejected")

var flipped = sealed
flipped[flipped.count - 1] ^= 1
check(PairingAuth.open(flipped, after: nil, key: macSide) == nil, "a damaged tag is rejected")
var bodyFlipped = sealed
bodyFlipped[5] ^= 1
check(PairingAuth.open(bodyFlipped, after: nil, key: macSide) == nil, "damaged input is rejected")
var counterFlipped = sealed
counterFlipped[1] ^= 1
check(PairingAuth.open(counterFlipped, after: nil, key: macSide) == nil, "a changed counter is rejected")
check(PairingAuth.open(Data([PacketKind.sealed.rawValue, 1, 2]), after: nil, key: macSide) == nil, "a truncated packet is rejected")

// Pairing code
let code = PairingAuth.code(handshake)
check(code.count == 6 && code.allSatisfy(\.isNumber), "the pairing code is six digits")
check(code == PairingAuth.code(handshake), "both ends compute the same code")

// Packets
var nan = PacketWriter(.move)
nan.f32(.nan)
var nanReader = PacketReader(nan.data)
nanReader.skipKind()
check(nanReader.f32() == nil, "NaN is rejected")
var inf = PacketWriter(.move)
inf.f32(.infinity)
var infReader = PacketReader(inf.data)
infReader.skipKind()
check(infReader.f32() == nil, "infinity is rejected")
var short = PacketReader(Data([PacketKind.move.rawValue, 1, 2]))
short.skipKind()
check(short.f32() == nil, "a truncated float is rejected")
var u32Writer = PacketWriter(.sealed)
u32Writer.u32(0xDEADBEEF)
var u32Reader = PacketReader(u32Writer.data)
u32Reader.skipKind()
check(u32Reader.u32() == 0xDEADBEEF, "u32 round-trips")

check(utf8Prefix("a🙂b", maxBytes: 3) == "a", "text is never cut inside a character")
check(utf8Prefix("a🙂b", maxBytes: 5) == "a🙂", "text fits as much as it can")

// Keys
check(MacKey.code(for: "c") == 8 && MacKey.code(for: "C") == 8, "letters map to their keys in either case")
check(MacKey.code(for: "é") == nil, "letters off the US layout have no key")
check(MacKey.chord(for: "+")?.code == 24 && MacKey.chord(for: "+")?.shift == true, "shifted symbols use their key plus Shift")
check(MacKey.chord(for: "=")?.code == 24 && MacKey.chord(for: "=")?.shift == false, "unshifted symbols don't add Shift")
check(MacKey.chord(for: "C")?.code == 8 && MacKey.chord(for: "C")?.shift == true, "capitals add Shift")
check(MacKey.chord(for: "c")?.shift == false, "lowercase doesn't add Shift")
check(MacKey.chord(for: "🙂") == nil, "emoji have no key")

// Geometry
let side = DisplayMap(rects: [CGRect(x: 0, y: 0, width: 1000, height: 800),
                              CGRect(x: 1000, y: 0, width: 500, height: 400)])
check(side.clamp(CGPoint(x: 1200, y: 100)) == CGPoint(x: 1200, y: 100), "a point on the second display stays")
check(side.clamp(CGPoint(x: 1200, y: 600)) == CGPoint(x: 999, y: 600), "a point below the short display moves to the tall one")
check(side.clamp(CGPoint(x: -50, y: -50)) == .zero, "a point off the corner clamps to the corner")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
