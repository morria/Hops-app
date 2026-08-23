import SwiftUI

/// First run: the pairing screen is the onboarding.
struct PairingView: View {
    @EnvironmentObject private var radio: RadioManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                deviceList
            }
            .navigationTitle("Welcome to Hops")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { radio.beginPairingScan() }
        .onDisappear { radio.endPairingScan() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Pair your Meshtastic radio")
                .font(.title3.weight(.semibold))
            Text("Turn your radio on and keep it nearby. Messages are text only, up to ~200 characters — that's LoRa mesh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 28)
    }

    private var deviceList: some View {
        List {
            if radio.discovered.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for radios…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Nearby radios") {
                    ForEach(radio.discovered) { device in
                        Button {
                            radio.pair(with: device.id)
                        } label: {
                            HStack {
                                Image(systemName: "flipphone")
                                    .foregroundStyle(Color.accentColor)
                                Text(device.name)
                                Spacer()
                                signalBars(rssi: device.rssi)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .bottom) {
            Text("iOS will ask for a PIN the first time — it's shown on your radio's screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
        }
    }

    private func signalBars(rssi: Int) -> some View {
        let strength: Int = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        return HStack(spacing: 2) {
            ForEach(0..<3) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar < strength ? Color.accentColor : Color(.systemGray4))
                    .frame(width: 4, height: CGFloat(6 + bar * 4))
            }
        }
        .accessibilityLabel("Signal strength \(strength) of 3")
    }
}
