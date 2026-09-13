import Foundation

/// The channel identity the firmware actually hashes (GitHub #5, #6).
///
/// v2.7.x `Channels::getName` substitutes the modem preset's display name
/// for a blank name (or "Custom" when presets are off), and
/// `Channels::generateHash` is `xorHash(name) ^ xorHash(expandedKey)`.
/// Two radios decode each other only when this byte matches, so it is the
/// one value worth showing.
enum ChannelIdentity {
    /// Firmware's default PSK (`defaultpsk` in `Channels.cpp`).
    static let defaultPSK: [UInt8] = [0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
                                      0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01]

    /// `DisplayFormatters::getModemPresetDisplayName(preset, false, usePreset)`.
    static func presetDisplayName(presetRaw: Int, usePreset: Bool = true) -> String {
        guard usePreset else { return "Custom" }
        switch presetRaw {
        case 0: return "LongFast"
        case 1: return "LongSlow"
        case 2: return "VLongSlow"
        case 3: return "MediumSlow"
        case 4: return "MediumFast"
        case 5: return "ShortSlow"
        case 6: return "ShortFast"
        case 7: return "LongMod"
        case 8: return "ShortTurbo"
        default: return "Invalid"
        }
    }

    /// The name that goes into the hash.
    static func effectiveName(name: String, presetRaw: Int, usePreset: Bool = true) -> String {
        name.isEmpty ? presetDisplayName(presetRaw: presetRaw, usePreset: usePreset) : name
    }

    /// `Channels::getKey`: 0 bytes = no key; 1 byte = default key variant
    /// (index 1…10 bumps the last byte); 16/32 bytes = as given; nil = invalid.
    static func expandedKey(_ psk: Data) -> Data? {
        switch psk.count {
        case 0: return Data()
        case 1:
            let index = Int(psk[psk.startIndex])
            if index == 0 { return Data() }
            guard index <= 10 else { return nil }
            var key = defaultPSK
            key[key.count - 1] = key[key.count - 1] &+ UInt8(index - 1)
            return Data(key)
        case 16, 32: return psk
        default: return nil
        }
    }

    static func xorHash<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }

    /// The channel hash byte, or nil when the key is invalid.
    static func hash(name: String, presetRaw: Int, psk: Data, usePreset: Bool = true) -> UInt8? {
        guard let key = expandedKey(psk) else { return nil }
        let effective = effectiveName(name: name, presetRaw: presetRaw, usePreset: usePreset)
        return xorHash(Array(effective.utf8)) ^ xorHash(key)
    }
}
