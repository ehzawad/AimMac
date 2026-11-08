// Shared by the Mac receiver and the iPhone app.
//
// Bluetooth LE layout
//   The Mac advertises one service. The phone connects, subscribes to `status`
//   and writes packets to `input` (write without response).
//
// Packets (little endian, first byte = kind)
//   hello   01  version:u8 key[32] ephemeral[32] commitment[32] name:utf8
//   info    09  battery:u8 (255 = unknown) model:utf8
//   proof   0B  nonce[16] signature[64]              reveals the committed nonce, answers the challenge
//   sealed  10  counter:u32 ciphertext tag[16]       one of the inputs below, encrypted
//
// Inputs (only ever inside `sealed`)
//   down    03  button:u8 drag:u8                    0 = left, 1 = right; drag 1 = never part of a double-click
//   up      04  button:u8
//   scroll  06  dx:f32 dy:f32                        pixels, natural direction
//   move    0A  dx:f32 dy:f32                        pixels
//   text    0C  utf8                                 typed characters
//   key     0D  code:u8 modifiers:u8                 macOS virtual key code
//   alive   0E                                       still holding a button (see InputEngine's lease)
//   phase   0F  signal:u8                            where a scroll is in its life (see ScrollSignal)
//
// Status (Mac -> phone, read + notify)
//   state:u8 (0 waiting for approval, 1 approved, 2 denied, 3 challenge ready)  paused:u8  macName:utf8
//
// Challenge (Mac -> phone, read)
//   macKey[32] macEphemeral[32] macNonce[16] signature[64]
//
// Pairing: each side owns an Ed25519 key and makes a fresh X25519 key for every
// connection. Both are signed during the handshake, so the phone knows it has
// the Mac it paired with, the Mac knows it has the phone it approved, and all
// input travels under a key only those two have. See `PairingAuth`.

import Foundation
import CoreBluetooth

@MainActor
enum TM {
    static let service = CBUUID(string: "7E1A0001-3C2B-4F7D-9B61-2A9E5D0C4F10")
    static let input   = CBUUID(string: "7E1A0002-3C2B-4F7D-9B61-2A9E5D0C4F10")
    static let status  = CBUUID(string: "7E1A0003-3C2B-4F7D-9B61-2A9E5D0C4F10")
    static let auth    = CBUUID(string: "7E1A0004-3C2B-4F7D-9B61-2A9E5D0C4F10")
}

enum PacketKind: UInt8 {
    case hello = 0x01
    case down = 0x03, up = 0x04
    case scroll = 0x06
    case info = 0x09
    case move = 0x0A
    case proof = 0x0B
    case text = 0x0C
    case key = 0x0D
    case alive = 0x0E
    case phase = 0x0F
    case sealed = 0x10
}

enum LinkState: UInt8 {
    case waiting = 0, approved = 1, denied = 2, challenge = 3
}

enum MouseButton: UInt8, Sendable {
    case left = 0, right = 1
}

/// Lets the Mac mark scrolling the way a real trackpad does.
enum ScrollSignal: UInt8, Sendable {
    case fingersBegan = 1, fingersEnded, momentumBegan, momentumEnded
}

struct KeyModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let command = KeyModifiers(rawValue: 1)
    static let option  = KeyModifiers(rawValue: 2)
    static let control = KeyModifiers(rawValue: 4)
    static let shift   = KeyModifiers(rawValue: 8)
}

/// macOS virtual key codes, by physical position on a US keyboard.
enum MacKey {
    static let returnKey: UInt8 = 36
    static let tab: UInt8 = 48
    static let delete: UInt8 = 51
    static let escape: UInt8 = 53
    static let left: UInt8 = 123
    static let right: UInt8 = 124
    static let down: UInt8 = 125
    static let up: UInt8 = 126
    static let d: UInt8 = 2
    static let equals: UInt8 = 24
    static let minus: UInt8 = 27

    private static let table: [Character: UInt8] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        " ": 49, "`": 50,
    ]

    /// Symbols typed with Shift, by the unshifted character on the same key.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key that types `c`, for shortcuts such as ⌘C.
    static func code(for c: Character) -> UInt8? {
        table[Character(c.lowercased())]
    }

    /// The key and Shift state that type `c`, or nil if no US key does.
    static func chord(for c: Character) -> (code: UInt8, shift: Bool)? {
        if let base = shifted[c], let code = table[base] { return (code, true) }
        guard let code = code(for: c) else { return nil }
        return (code, c.isUppercase)
    }
}

/// The longest prefix of `s` that fits in `maxBytes` of UTF-8 without splitting a character.
func utf8Prefix(_ s: String, maxBytes: Int) -> String {
    var used = 0
    var out = ""
    for ch in s {
        let n = ch.utf8.count
        guard used + n <= maxBytes else { break }
        used += n
        out.append(ch)
    }
    return out
}

struct PacketWriter {
    private(set) var data = Data()

    init(_ kind: PacketKind) { data.append(kind.rawValue) }

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    mutating func u32(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ d: Data) { data.append(d) }

    /// Rest-of-packet string, cut to keep packets small.
    mutating func string(_ s: String, max: Int = 60) {
        data.append(contentsOf: utf8Prefix(s, maxBytes: max).utf8)
    }
}

struct PacketReader {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var kind: PacketKind? {
        guard let b = bytes.first else { return nil }
        return PacketKind(rawValue: b)
    }

    /// Call once before reading fields to skip the kind byte.
    mutating func skipKind() { i = 1 }

    mutating func u8() -> UInt8? {
        guard i < bytes.count else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    mutating func u32() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        defer { i += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << (8 * UInt32($1)) }
    }

    /// A float, or nil if it is missing, NaN or infinite.
    mutating func f32() -> Float? {
        guard let r = u32() else { return nil }
        let v = Float(bitPattern: r)
        return v.isFinite ? v : nil
    }

    mutating func data(_ n: Int) -> Data? {
        guard i + n <= bytes.count else { return nil }
        defer { i += n }
        return Data(bytes[i..<(i + n)])
    }

    mutating func restData() -> Data {
        guard i < bytes.count else { return Data() }
        defer { i = bytes.count }
        return Data(bytes[i...])
    }

    mutating func rest() -> String { String(decoding: restData(), as: UTF8.self) }
}
