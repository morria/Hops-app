import SwiftUI

/// Pair, see status, forget. The watch needs its own pairing: Bluetooth
/// identities don't carry over from the phone.
struct RadioView: View {
    @EnvironmentObject private var radio: WatchRadio

    var body: some View {
        List {
            if radio.hasRadio {
                Section("Radio") {
                    LabeledContent("Name", value: radio.radioName)
                    LabeledContent("Status", value: WatchRadio.statusText(radio.state))
                    if radio.myNodeNum > 0 {
                        LabeledContent("Node", value: String(format: "!%08x", UInt32(truncatingIfNeeded: radio.myNodeNum)))
                    }
                    if radio.state == .offline {
                        Text("A radio takes one Bluetooth connection at a time. If your phone is connected to it, disconnect there first.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Forget Radio", role: .destructive) { radio.forget() }
                }
            }
            Section(radio.hasRadio ? "Switch radio" : "Nearby radios") {
                if radio.scanning {
                    ForEach(radio.discovered) { device in
                        Button {
                            radio.pair(with: device)
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi) dB").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if radio.discovered.isEmpty {
                        HStack { ProgressView(); Text("Scanning…").font(.caption) }
                    }
                    Button("Stop Scanning") { radio.stopScan() }
                } else {
                    Button("Scan for Radios") { radio.startScan() }
                }
            }
        }
        .navigationTitle("Radio")
        .onDisappear { radio.stopScan() }
    }
}
