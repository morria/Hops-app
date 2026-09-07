import Foundation

/// Meshtastic stores owner names as fixed-size C strings on the radio:
/// 4 bytes for the short name and 39 for the long name (each plus a NUL).
/// Those limits are UTF-8 *bytes*, not characters — a plain emoji is 4
/// bytes, a flag or skin-toned emoji 8 or more, a ZWJ family up to 25.
/// A name that overflows makes the radio's protobuf decoder reject the
/// whole admin message, silently, so the rename never happens (TODO 177).
/// Everything that sets or edits a name goes through here.
enum MeshName {
    static let shortMaxBytes = 4
    static let longMaxBytes = 39

    static func byteCount(_ s: String) -> Int { s.utf8.count }

    /// Longest prefix of `s` that fits in `maxBytes` without splitting a
    /// grapheme cluster. A first cluster that is itself too big yields "".
    static func clamp(_ s: String, maxBytes: Int) -> String {
        var used = 0
        var out = ""
        for ch in s {
            let n = ch.utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    static func clampShort(_ s: String) -> String { clamp(s, maxBytes: shortMaxBytes) }
    static func clampLong(_ s: String) -> String { clamp(s, maxBytes: longMaxBytes) }
    static func fitsShort(_ s: String) -> Bool { byteCount(s) <= shortMaxBytes }
    static func fitsLong(_ s: String) -> Bool { byteCount(s) <= longMaxBytes }

    /// True when a name uses anything beyond ASCII, i.e. when the byte
    /// budget stops matching the character count the user sees.
    static func isMultibyte(_ s: String) -> Bool { s.utf8.contains { $0 >= 0x80 } }

    /// Footer line for the name editors; nil while both names are plain
    /// ASCII (the budget then equals the visible length and needs no note).
    static func budgetNote(long: String, short: String) -> String? {
        guard isMultibyte(long) || isMultibyte(short) else { return nil }
        return "Names are stored as bytes on the radio: short name \(byteCount(short)) of \(shortMaxBytes), long name \(byteCount(long)) of \(longMaxBytes). A plain emoji is 4 bytes; flags and skin-tone emoji are 8 or more and won't fit a short name."
    }
}
