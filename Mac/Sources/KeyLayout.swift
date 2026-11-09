import Carbon.HIToolbox
import Foundation

/// The phone names keys by where they sit on a US keyboard, but a shortcut has
/// to mean the same letter on every layout. On a French keyboard the key in the
/// US Z position types W, so an uncorrected Command-Z would close a window.
enum KeyLayout {
    /// Where the selected keyboard keeps each character, for the keys that moved.
    /// Text Input Sources must be read on the main thread.
    @MainActor
    static func currentShortcutKeys() -> [UInt8: UInt8] {
        for source in [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()] {
            guard let source, let layout = layoutData(of: source) else { continue }
            return shortcutKeys(layout: layout)
        }
        return [:]
    }

    static func layoutData(of source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    /// US key position to this layout's position, leaving out keys that didn't move.
    static func shortcutKeys(layout: Data) -> [UInt8: UInt8] {
        let isoKey: UInt8 = 10  // the extra key beside Shift on ISO keyboards
        var positions: [Character: UInt8] = [:]
        for code in Set(MacKey.characterKeys.values).union([isoKey]).sorted() {
            if let character = character(at: code, layout: layout), positions[character] == nil {
                positions[character] = code
            }
        }
        var moved: [UInt8: UInt8] = [:]
        for (character, usCode) in MacKey.characterKeys {
            if let here = positions[character], here != usCode { moved[usCode] = here }
        }
        return moved
    }

    /// What this key types with Command held, which is what shortcuts match against.
    private static func character(at code: UInt8, layout: Data) -> Character? {
        layout.withUnsafeBytes { bytes -> Character? in
            guard let pointer = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDisplay),
                                        UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeys, units.count, &length, &units)
            guard status == noErr, length == 1 else { return nil }
            return String(utf16CodeUnits: units, count: 1).lowercased().first
        }
    }
}
