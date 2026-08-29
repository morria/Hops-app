import Foundation
import MeshtasticProtobufs

/// A community's published radio configuration. Presets are versioned data, not code:
/// metros change their recommendations (Bay Area moved MediumSlow → MediumFast in late
/// 2025; NYC began migrating to MediumSlow in early 2026), so the bundled manifest is
/// refreshed from a maintained remote source when available.
struct MetroPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var summary: String
    var regionRaw: Int
    var presetRaw: Int
    var frequencySlot: Int
    var hopLimit: Int
    var source: String?
    var updated: String?
    /// Optional bundled image shown as the primary channel's avatar while this
    /// metro's configuration is applied (e.g. the NYME.SH logo).
    var channelIconAsset: String?
    /// Optional service area — lets the app surface "near you" presets.
    var latitude: Double?
    var longitude: Double?
    var radiusKm: Double?

    /// Rough great-circle containment test against the service area.
    func covers(latitude lat: Double, longitude lon: Double) -> Bool {
        guard let clat = latitude, let clon = longitude, let radius = radiusKm else { return false }
        let dLat = (lat - clat) * 111.0
        let dLon = (lon - clon) * 111.0 * cos(clat * .pi / 180)
        return dLat * dLat + dLon * dLon <= radius * radius
    }

    var regionName: String {
        let region = Config.LoRaConfig.RegionCode(rawValue: regionRaw) ?? .unset
        return region == .unset ? "Not set" : String(describing: region).uppercased()
    }

    var presetName: String {
        switch Config.LoRaConfig.ModemPreset(rawValue: presetRaw) {
        case .longFast: return "LongFast"
        case .mediumFast: return "MediumFast"
        case .mediumSlow: return "MediumSlow"
        case .longSlow: return "LongSlow"
        case .shortFast: return "ShortFast"
        case .shortSlow: return "ShortSlow"
        default: return "Custom"
        }
    }
}

struct MetroPresetManifest: Codable, Equatable {
    var version: Int
    var presets: [MetroPreset]
}

@MainActor
final class MetroPresetStore: ObservableObject {

    static let shared = MetroPresetStore()

    @Published private(set) var manifest: MetroPresetManifest
    @Published private(set) var customPresets: [MetroPreset] = []
    @Published var appliedPresetId: String? {
        didSet { UserDefaults.standard.set(appliedPresetId, forKey: Self.appliedKey) }
    }

    /// Community presets followed by the user's own saved configurations.
    var allPresets: [MetroPreset] { manifest.presets + customPresets }

    func isCustom(_ preset: MetroPreset) -> Bool {
        preset.id.hasPrefix("custom-")
    }

    func addCustom(name: String, regionRaw: Int, presetRaw: Int, frequencySlot: Int, hopLimit: Int) -> MetroPreset {
        var preset = MetroPreset(id: "custom-\(UUID().uuidString)", name: name,
                                 summary: "", regionRaw: regionRaw, presetRaw: presetRaw,
                                 frequencySlot: frequencySlot, hopLimit: hopLimit,
                                 source: nil, updated: nil, channelIconAsset: nil,
                                 latitude: nil, longitude: nil, radiusKm: nil)
        preset.summary = "\(preset.presetName), slot \(frequencySlot), hop limit \(hopLimit) — your saved configuration."
        customPresets.append(preset)
        persistCustom()
        return preset
    }

    func removeCustom(id: String) {
        customPresets.removeAll { $0.id == id }
        if appliedPresetId == id { appliedPresetId = nil }
        persistCustom()
    }

    private static let customKey = "customMetroPresets"

    private func persistCustom() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }

    /// The avatar for a channel conversation: the applied metro's icon for the
    /// primary channel, nil (monogram fallback) otherwise.
    func channelIconAsset(forChannelIndex index: Int32) -> String? {
        guard index == 0, let id = appliedPresetId else { return nil }
        return allPresets.first(where: { $0.id == id })?.channelIconAsset
    }

    /// Adopt a preset as "applied" when the radio's live config matches it exactly
    /// but no application was recorded (pre-tracking builds, or configured by
    /// another app). Never overrides an explicit record.
    func inferAppliedPreset(regionRaw: Int, presetRaw: Int, frequencySlot: Int) {
        guard appliedPresetId == nil else { return }
        if let match = allPresets.first(where: {
            $0.regionRaw == regionRaw && $0.presetRaw == presetRaw && $0.frequencySlot == frequencySlot
        }) {
            appliedPresetId = match.id
        }
    }

    private static let cacheKey = "metroPresetManifest"
    private static let appliedKey = "appliedMetroPresetId"
    /// Point this at a maintained raw-JSON URL (e.g. the Hops repo) to ship preset
    /// updates without an app release. Fails silently; the bundled copy always works.
    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/hops-mesh/presets/main/metro-presets.json")

    private init() {
        if let cached = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode(MetroPresetManifest.self, from: cached) {
            manifest = decoded
        } else {
            manifest = Self.bundled()
        }
        appliedPresetId = UserDefaults.standard.string(forKey: Self.appliedKey)
        if let data = UserDefaults.standard.data(forKey: Self.customKey),
           let decoded = try? JSONDecoder().decode([MetroPreset].self, from: data) {
            customPresets = decoded
        }
    }

    private static func bundled() -> MetroPresetManifest {
        guard let url = Bundle.main.url(forResource: "metro-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MetroPresetManifest.self, from: data) else {
            return MetroPresetManifest(version: 0, presets: [])
        }
        return decoded
    }

    func refresh() async {
        guard let url = Self.remoteURL else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(MetroPresetManifest.self, from: data),
              decoded.version > manifest.version else { return }
        manifest = decoded
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
