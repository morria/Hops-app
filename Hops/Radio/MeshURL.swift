import Foundation
import CoreImage.CIFilterBuiltins
import UIKit
import MeshtasticProtobufs

/// The standard Meshtastic channel-share URL: https://meshtastic.org/e/#<base64url ChannelSet>
enum MeshURL {

    /// A parsed share link. `add` means "append these channels to free slots,
    /// leave everything else alone" — the `?add=true` form the official app
    /// uses for single-channel invites (TODO 183). A link that carries no
    /// LoRa config is treated as an add too: nothing in it justifies
    /// replacing the primary.
    struct Link {
        let channelSet: ChannelSet
        let add: Bool
    }

    static func parseLink(_ string: String) -> Link? {
        guard let hashIndex = string.firstIndex(of: "#") else { return nil }
        let prefix = String(string[..<hashIndex])
        var fragment = String(string[string.index(after: hashIndex)...])
        var addFlag = hasAddFlag(prefix.components(separatedBy: "?").dropFirst().joined(separator: "?"))
        if let q = fragment.firstIndex(of: "?") {
            addFlag = addFlag || hasAddFlag(String(fragment[fragment.index(after: q)...]))
            fragment = String(fragment[..<q])
        }
        var base64 = fragment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let channelSet = try? ChannelSet(serializedBytes: data) else { return nil }
        return Link(channelSet: channelSet, add: addFlag || !channelSet.hasLoraConfig)
    }

    private static func hasAddFlag(_ query: String) -> Bool {
        query.lowercased().components(separatedBy: "&").contains { $0 == "add=true" || $0 == "add=1" }
    }

    static func parse(_ string: String) -> ChannelSet? { parseLink(string)?.channelSet }

    static func encode(_ channelSet: ChannelSet, add: Bool = false) -> String? {
        guard let data = try? channelSet.serializedData() else { return nil }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "https://meshtastic.org/e/\(add ? "?add=true" : "")#\(base64)"
    }

    /// Invite link for one channel: add-mode, no LoRa config, so scanning it
    /// appends the channel instead of replacing the recipient's mesh.
    static func encodeSingle(name: String, psk: Data) -> String? {
        var settings = ChannelSettings()
        settings.name = name
        settings.psk = psk
        var set = ChannelSet()
        set.settings = [settings]
        return encode(set, add: true)
    }

    static func qrImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Human-readable description of what applying this ChannelSet would change.
    static func describeImport(_ channelSet: ChannelSet, current: RadioManager.LoRaSnapshot) -> [String] {
        var lines: [String] = []
        for (index, settings) in channelSet.settings.enumerated() {
            let name = settings.name.isEmpty ? (index == 0 ? "Primary" : "Channel \(index)") : settings.name
            lines.append("Channel \(index): \(name)\(settings.psk.isEmpty ? "" : " (encrypted)")")
        }
        if channelSet.hasLoraConfig {
            let lora = channelSet.loraConfig
            if lora.region != .unset, lora.region.rawValue != current.regionRaw {
                lines.append("Region → \(String(describing: lora.region).uppercased())")
            }
            if lora.modemPreset.rawValue != current.presetRaw {
                lines.append("Modem preset → \(String(describing: lora.modemPreset))")
            }
            if Int(lora.channelNum) != current.frequencySlot {
                lines.append("Frequency slot → \(lora.channelNum)")
            }
        }
        return lines
    }
}
