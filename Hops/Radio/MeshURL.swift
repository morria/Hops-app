import Foundation
import CoreImage.CIFilterBuiltins
import UIKit
import MeshtasticProtobufs

/// The standard Meshtastic channel-share URL: https://meshtastic.org/e/#<base64url ChannelSet>
enum MeshURL {

    static func parse(_ string: String) -> ChannelSet? {
        guard let hashIndex = string.firstIndex(of: "#") else { return nil }
        var base64 = String(string[string.index(after: hashIndex)...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? ChannelSet(serializedBytes: data)
    }

    static func encode(_ channelSet: ChannelSet) -> String? {
        guard let data = try? channelSet.serializedData() else { return nil }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "https://meshtastic.org/e/#\(base64)"
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
