import SwiftUI
import MeshtasticProtobufs

/// Manual LoRa configuration — the full dial set behind the metro presets.
/// Saving a config that exactly matches a known preset re-adopts that preset
/// (and its channel icon) automatically via the inference on the next sync.
struct LoRaSettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var regionRaw = 1
    @State private var presetRaw = 0
    @State private var slotText = "0"
    @State private var hopLimit = 3

    private static let regions: [(String, Int)] = Config.LoRaConfig.RegionCode.allCases
        .filter { $0 != .unset && $0 != .UNRECOGNIZED(0) }
        .map { (String(describing: $0).uppercased(), $0.rawValue) }

    private static let presets: [(String, Int)] = Config.LoRaConfig.ModemPreset.allCases
        .filter { if case .UNRECOGNIZED = $0 { return false } ; return true }
        .map { (String(describing: $0), $0.rawValue) }

    var body: some View {
        Form {
            Section {
                Picker("Region", selection: $regionRaw) {
                    ForEach(Self.regions, id: \.1) { name, value in
                        Text(name).tag(value)
                    }
                }
                Picker("Modem preset", selection: $presetRaw) {
                    ForEach(Self.presets, id: \.1) { name, value in
                        Text(name).tag(value)
                    }
                }
                LabeledContent("Frequency slot") {
                    TextField("0 = auto", text: $slotText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onChange(of: slotText) { _, newValue in
                            slotText = String(newValue.filter(\.isNumber).prefix(3))
                        }
                }
                Stepper("Hop limit: \(hopLimit)", value: $hopLimit, in: 1...7)
            } footer: {
                Text("Everyone on a mesh must share region, preset, and slot. Slot 0 derives the default from the channel name. Prefer a metro preset when one fits — this screen is for going off-book.")
            }
            Section {
                Button {
                    radio.applyLoRaConfig(regionRaw: regionRaw,
                                          presetRaw: presetRaw,
                                          frequencySlot: Int(slotText) ?? 0,
                                          hopLimit: hopLimit)
                    dismiss()
                } label: {
                    Text("Save to Radio")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("The radio restarts to apply LoRa changes; Hops reconnects automatically.")
            }
        }
        .navigationTitle("LoRa Radio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard radio.loRa.received else { return }
            regionRaw = radio.loRa.regionRaw
            presetRaw = radio.loRa.presetRaw
            slotText = String(radio.loRa.frequencySlot)
            hopLimit = radio.loRa.hopLimit
        }
    }
}
