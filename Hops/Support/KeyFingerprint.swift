import Foundation
import CryptoKit

extension Data {
    /// Human-comparable digest of a PKI public key (SHA-256, grouped hex) —
    /// identical formatting wherever fingerprints appear, so two people reading
    /// theirs aloud can match them group by group.
    var keyFingerprint: String {
        let digest = SHA256.hash(data: self)
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}
