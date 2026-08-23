import SwiftUI
import MeshtasticProtobufs

/// How often the radio broadcasts its own metrics (battery etc.) to the mesh.
/// Firmware defaults to 30 minutes; metro communities recommend 6 hours to
/// save shared airtime.
struct TelemetrySettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var deviceInterval = 1800

    private static let intervalChoices: [(String, Int)] = [
        ("30 minutes (firmware default)", 1800),
        ("1 hour", 3600),
        ("2 hours", 7200),
        ("6 hours (community recommended)", 21600),
        ("12 hours", 43200),
        ("24 hours", 86400),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Battery & device metrics", selection: $deviceInterval) {
                    ForEach(Self.intervalChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Broadcast interval")
            } footer: {
                Text("Every broadcast spends the whole mesh's airtime. Unless your battery level is of citywide interest, 6 hours is plenty — bayme.sh and nyme.sh both recommend it.")
            }
            Section {
                Button {
                    var telemetry = radio.telemetryConfig ?? ModuleConfig.TelemetryConfig()
                    telemetry.deviceUpdateInterval = UInt32(deviceInterval)
                    var moduleConfig = ModuleConfig()
                    moduleConfig.telemetry = telemetry
                    radio.applyModuleConfig(moduleConfig)
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
                Text("The radio may restart briefly to apply; Hops reconnects automatically.")
            }
        }
        .navigationTitle("Telemetry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let telemetry = radio.telemetryConfig, telemetry.deviceUpdateInterval > 0 {
                let current = Int(telemetry.deviceUpdateInterval)
                deviceInterval = Self.intervalChoices.map(\.1).contains(current) ? current : 1800
            }
        }
    }
}
