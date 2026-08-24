import SwiftUI
import SwiftData

/// Guided first run: find the radio → pair → watch it sync → name yourself →
/// pick your mesh → start messaging. Every state explains itself.
struct PairingView: View {
    @EnvironmentObject private var radio: RadioManager
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Query private var nodes: [NodeEntity]

    @State private var showTips = false
    @State private var longName = ""
    @State private var shortName = ""
    @State private var nameEdited = false

    private enum Phase {
        case bluetoothOff, scanning, connecting, ready
    }

    private var phase: Phase {
        switch radio.state {
        case .bluetoothOff: return .bluetoothOff
        case .noRadio: return .scanning
        case .connected: return .ready
        default: return .connecting
        }
    }

    private var myNode: NodeEntity? {
        nodes.first { $0.num == radio.myNodeNum }
    }

    private var hasFactoryName: Bool {
        guard let name = myNode?.longName else { return false }
        return name.hasPrefix("Meshtastic") || name.hasPrefix("Node ")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .bluetoothOff: bluetoothOffView
                case .scanning: scanView
                case .connecting: connectingView
                case .ready: readyView
                }
            }
            .navigationTitle("Welcome to Hops")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if phase == .scanning { radio.beginPairingScan() }
            Task {
                try? await Task.sleep(for: .seconds(12))
                showTips = true
            }
        }
        .onDisappear { radio.endPairingScan() }
    }

    // MARK: - Bluetooth off

    private var bluetoothOffView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Bluetooth is off")
                .font(.title3.weight(.semibold))
            Text("Hops talks to your Meshtastic radio over Bluetooth. Turn it on in Control Center or Settings, and we'll take it from there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Scanning

    private var scanView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("Pair your Meshtastic radio")
                    .font(.title3.weight(.semibold))
                Text("Turn your radio on and keep it nearby.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.vertical, 28)

            List {
                if radio.discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for radios…")
                            .foregroundStyle(.secondary)
                    }
                    if showTips {
                        Section("Not finding it?") {
                            Label("Check the radio is powered on and charged", systemImage: "power")
                            Label("Bring it within a few feet of your phone", systemImage: "ruler")
                            Label("If it's paired to another phone, disconnect there first — radios hold one Bluetooth connection at a time", systemImage: "iphone.slash")
                        }
                        .font(.subheadline)
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text("iOS will ask for a PIN the first time — it's shown on your radio's screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Use Without a Radio") {
                    onboardingComplete = true
                    radio.finishOnboarding()
                }
                .font(.subheadline)
                Text("Messages you write sync via iCloud and transmit through your other device's radio.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - Connecting / syncing

    private var connectingView: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 12) {
                step(done: radio.state == .syncing || radio.state == .connected,
                     active: radio.state == .connecting || radio.state == .offline,
                     label: "Connecting to your radio")
                step(done: radio.state == .connected,
                     active: radio.state == .syncing,
                     label: "Syncing channels & mesh")
            }
            if radio.state == .offline {
                Text("Radio out of reach — move closer and Hops will retry automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
            Spacer()
        }
    }

    private func step(done: Bool, active: Bool, label: String) -> some View {
        HStack(spacing: 12) {
            if done && !active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if active {
                ProgressView()
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
            }
            Text(label)
                .foregroundStyle(active || done ? .primary : .secondary)
        }
        .font(.body)
    }

    // MARK: - Ready

    private var readyView: some View {
        Form {
            Section {
                Label {
                    Text("Connected and synced")
                        .font(.headline)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if hasFactoryName || nameEdited {
                Section {
                    TextField("Your name (e.g. Andrew / W2ASM)", text: $longName)
                        .onChange(of: longName) { _, _ in nameEdited = true }
                    TextField("Short name (4 characters, on maps)", text: $shortName)
                        .onChange(of: shortName) { _, newValue in
                            shortName = String(newValue.prefix(4))
                            nameEdited = true
                        }
                } header: {
                    Text("What should the mesh call you?")
                } footer: {
                    Text("Your radio still has its factory name. This is how you appear to everyone.")
                }
            }

            if radio.needsMeshSetup {
                Section {
                    NavigationLink {
                        MeshSetupView(isFirstRun: true)
                    } label: {
                        Label("Choose your mesh", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Color.accentColor)
                    }
                } footer: {
                    Text("Your radio's region isn't set yet, so it can't transmit. One tap configures it for your local mesh.")
                }
            }

            Section {
                Button {
                    finish()
                } label: {
                    Text("Start Messaging")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(radio.needsMeshSetup)
            } footer: {
                if radio.needsMeshSetup {
                    Text("Choose your mesh first — without a region the radio stays silent.")
                }
            }
        }
        .onAppear {
            if let node = myNode, hasFactoryName {
                longName = ""
                shortName = ""
                _ = node // fields start blank; placeholder guides
            }
        }
    }

    private func finish() {
        let trimmedLong = longName.trimmingCharacters(in: .whitespaces)
        let trimmedShort = shortName.trimmingCharacters(in: .whitespaces)
        if nameEdited, !trimmedLong.isEmpty, !trimmedShort.isEmpty {
            radio.setOwner(longName: trimmedLong, shortName: trimmedShort)
            if let node = myNode {
                node.longName = trimmedLong
                node.shortName = trimmedShort
            }
        }
        onboardingComplete = true
        radio.finishOnboarding()
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
