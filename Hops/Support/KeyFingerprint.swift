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

import SwiftUI

/// Large-format fingerprint for visual comparison: two rows of four groups,
/// big monospaced digits, alternating emphasis so the eye can track groups
/// while two people read them to each other.
struct KeyFingerprintView: View {
    let key: Data

    var body: some View {
        let groups = key.keyFingerprint.split(separator: " ").map(String.init)
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { col in
                        let index = row * 4 + col
                        if index < groups.count {
                            Text(groups[index])
                                .foregroundStyle(index % 2 == 0 ? AnyShapeStyle(.primary)
                                                                : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
        }
        .font(.system(.title3, design: .monospaced).weight(.medium))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}
