import SwiftUI
import SwiftData
import MeshtasticProtobufs

struct SettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Query private var nodes: [NodeEntity]

    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("notifyDMs") private var notifyDMs = true
    @AppStorage("notifyChannels") private var notifyChannels = true

    @State private var showForgetConfirm = false

    private var myNode: NodeEntity? {
        nodes.first(where: { $0.num == radio.myNodeNum })
    }

    var body: some View {
        NavigationStack {
            List {
                radioSection
                channelsSection
                deviceConfigSection
                notificationsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .refreshable {
                await radio.refreshDeviceStatus()
            }
        }
    }

    // MARK: - Radio

    private var radioSection: some View {
        Section("Radio") {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(myNode?.longName ?? "Meshtastic radio")
                        .font(.headline)
                    Text(stateDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = myNode?.batteryLevel, battery >= 0 {
                    Label(battery > 100 ? "Power" : "\(battery)%", systemImage: batteryIcon(battery))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            NavigationLink {
                IdentityView()
            } label: {
                LabeledContent("Your name", value: myNode.map { "\($0.longName) (\($0.shortName))" } ?? "Not set")
            }

            NavigationLink {
                MeshSetupView(isFirstRun: false)
            } label: {
                LabeledContent("Mesh setup") {
                    Text(radio.loRa.received
                         ? "\(radio.loRa.regionName) · \(radio.loRa.presetName)"
                         : "—")
                }
            }

            if !radio.firmwareVersion.isEmpty {
                LabeledContent("Firmware", value: radio.firmwareVersion)
            }

            NavigationLink {
                MeshTrafficLogView()
            } label: {
                LabeledContent("Mesh traffic") {
                    Text(trafficDescription)
                        .foregroundStyle(radio.meshPacketsHeard == 0 ? .orange : .secondary)
                }
            }

            if let mismatch = presetMismatch {
                NavigationLink {
                    MeshSetupView(isFirstRun: false)
                } label: {
                    Label {
                        Text("Radio doesn't match \(mismatch.name) (\(mismatch.presetName), slot \(mismatch.frequencySlot), hop limit \(mismatch.hopLimit)). Re-apply in Mesh Setup.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if radio.userDisconnected {
                Button("Connect") {
                    radio.reconnectByUser()
                }
            } else {
                Button("Disconnect") {
                    radio.disconnectByUser()
                }
            }

            Button("Forget This Radio…", role: .destructive) {
                showForgetConfirm = true
            }
            .confirmationDialog("Forget this radio?", isPresented: $showForgetConfirm, titleVisibility: .visible) {
                Button("Forget Radio", role: .destructive) { radio.forgetRadio() }
            } message: {
                Text("Messages stay on this phone. You can pair again anytime.")
            }
        }
    }

    private var stateColor: Color {
        switch radio.state {
        case .connected: return .green
        case .syncing, .connecting: return .orange
        default: return .secondary
        }
    }

    private var stateDescription: String {
        switch radio.state {
        case .connected: return "Connected"
        case .syncing: return "Syncing…"
        case .connecting: return "Connecting…"
        case .offline: return radio.userDisconnected ? "Disconnected" : "Not in range"
        case .bluetoothOff: return "Bluetooth is off"
        case .bondLost: return "Needs re-pairing"
        case .noRadio: return "Not paired"
        }
    }

    private var trafficDescription: String {
        if radio.meshPacketsHeard == 0 {
            return "None heard since launch"
        }
        var text = "\(radio.meshPacketsHeard) packets · \(radio.textMessagesHeard) messages"
        if let last = radio.lastMeshPacketAt {
            text += " · \(last.formatted(.relative(presentation: .named)))"
        }
        return text
    }

    /// The applied metro preset, when the radio's current LoRa config has drifted
    /// from it (e.g. preset values were corrected after it was applied).
    private var presetMismatch: MetroPreset? {
        guard radio.loRa.received,
              let id = MetroPresetStore.shared.appliedPresetId,
              let preset = MetroPresetStore.shared.manifest.presets.first(where: { $0.id == id })
        else { return nil }
        let current = radio.loRa
        let matches = current.regionRaw == preset.regionRaw
            && current.presetRaw == preset.presetRaw
            && current.frequencySlot == preset.frequencySlot
            && current.hopLimit == preset.hopLimit
        return matches ? nil : preset
    }

    private func batteryIcon(_ level: Int) -> String {
        if level > 100 { return "powerplug" }
        if level > 75 { return "battery.100" }
        if level > 50 { return "battery.75" }
        if level > 25 { return "battery.50" }
        return "battery.25"
    }

    // MARK: - Channels

    private var channelsSection: some View {
        Section("Channels") {
            NavigationLink {
                ChannelsView()
            } label: {
                Label("Channels & QR codes", systemImage: "qrcode")
            }
        }
    }

    // MARK: - Device configuration

    private var deviceConfigSection: some View {
        Section("Device configuration") {
            NavigationLink {
                BluetoothSettingsView()
            } label: {
                Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right.circle")
            }
            NavigationLink {
                DisplaySettingsView()
            } label: {
                Label("Display", systemImage: "sun.max")
            }
            NavigationLink {
                PositionSettingsView()
            } label: {
                Label("Position", systemImage: "location")
            }
            NavigationLink {
                TelemetrySettingsView()
            } label: {
                Label("Telemetry", systemImage: "battery.75percent")
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Allow Notifications", isOn: $notificationsEnabled)
            if notificationsEnabled {
                Toggle("Direct Messages", isOn: $notifyDMs)
                Toggle("Channel Messages", isOn: $notifyChannels)
            }
            Button("Notification Settings…") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Link(destination: URL(string: "https://meshtastic.org")!) {
                Text("Meshtastic Project")
            }
            Text("Hops configures the app. For device administration — modules, firmware, remote nodes — use the official Meshtastic app; both work with the same radio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return version
    }
}

// MARK: - Identity

struct IdentityView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss
    @Query private var nodes: [NodeEntity]

    @State private var longName = ""
    @State private var shortName = ""

    var body: some View {
        Form {
            Section {
                TextField("Long name", text: $longName)
                TextField("Short name (4 characters)", text: $shortName)
                    .onChange(of: shortName) { _, newValue in
                        shortName = String(newValue.prefix(4))
                    }
            } footer: {
                Text("How you appear to everyone on the mesh. The short name is your map marker and channel tag.")
            }
            Button("Save") {
                radio.setOwner(longName: longName, shortName: shortName)
                if let node = nodes.first(where: { $0.num == radio.myNodeNum }) {
                    node.longName = longName
                    node.shortName = shortName
                }
                dismiss()
            }
            .disabled(longName.trimmingCharacters(in: .whitespaces).isEmpty || shortName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("Your Name")
        .onAppear {
            if let node = nodes.first(where: { $0.num == radio.myNodeNum }) {
                longName = node.longName
                shortName = node.shortName
            }
        }
    }
}

// MARK: - Mesh setup (metro presets)

struct MeshSetupView: View {
    let isFirstRun: Bool

    @EnvironmentObject private var radio: RadioManager
    @StateObject private var presets = MetroPresetStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var confirming: MetroPreset?
    @State private var showSaveCustom = false
    @State private var customName = ""

    var body: some View {
        List {
            if isFirstRun {
                Section {
                    Label {
                        Text("Your radio's region isn't set, so it can't transmit yet. Pick your local mesh — one tap configures everything.")
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }
            Section {
                ForEach(presets.allPresets) { preset in
                    Button {
                        confirming = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(preset.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isCurrent(preset) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(preset.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        if presets.isCustom(preset) {
                            Button(role: .destructive) {
                                presets.removeCustom(id: preset.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                if radio.loRa.received {
                    Button {
                        showSaveCustom = true
                    } label: {
                        Label("Save Current as Preset…", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Set up for your mesh")
            } footer: {
                Text("Community recommendations, refreshed from each mesh's published settings, plus your own saved configurations (swipe to delete).")
            }
            Section {
                NavigationLink {
                    LoRaSettingsView()
                } label: {
                    Label("Custom LoRa Settings", systemImage: "dot.radiowaves.left.and.right")
                }
            } footer: {
                Text("Region, modem preset, frequency slot, and hop limit — for going off-book. Save the result as a preset above to get back easily.")
            }
            if radio.loRa.received {
                Section("Current radio settings") {
                    LabeledContent("Region", value: radio.loRa.regionName)
                    LabeledContent("Modem preset", value: radio.loRa.presetName)
                    LabeledContent("Frequency slot",
                                   value: radio.loRa.frequencySlot > 0 ? "\(radio.loRa.frequencySlot)" : "Default (0)")
                    LabeledContent("Hop limit", value: "\(radio.loRa.hopLimit)")
                }
            }
        }
        .navigationTitle("Mesh Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await presets.refresh() }
        .alert("Save Current as Preset", isPresented: $showSaveCustom) {
            TextField("Name (e.g. Cabin mesh)", text: $customName)
            Button("Save") {
                let name = customName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let preset = presets.addCustom(name: name,
                                               regionRaw: radio.loRa.regionRaw,
                                               presetRaw: radio.loRa.presetRaw,
                                               frequencySlot: radio.loRa.frequencySlot,
                                               hopLimit: radio.loRa.hopLimit)
                presets.appliedPresetId = preset.id
                customName = ""
            }
            Button("Cancel", role: .cancel) { customName = "" }
        } message: {
            Text("Saves the radio's current region, preset, slot, and hop limit as a named configuration in this list.")
        }
        .sheet(item: $confirming) { preset in
            NavigationStack {
                PresetConfirmView(preset: preset) {
                    radio.applyLoRaConfig(regionRaw: preset.regionRaw,
                                          presetRaw: preset.presetRaw,
                                          frequencySlot: preset.frequencySlot,
                                          hopLimit: preset.hopLimit,
                                          metroPresetId: preset.id)
                    confirming = nil
                    dismiss()
                }
            }
            .presentationDetents([.medium])
        }
        .toolbar {
            if isFirstRun {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
    }

    private func isCurrent(_ preset: MetroPreset) -> Bool {
        radio.loRa.received
            && radio.loRa.regionRaw == preset.regionRaw
            && radio.loRa.presetRaw == preset.presetRaw
            && radio.loRa.frequencySlot == preset.frequencySlot
    }
}

/// The one-screen confirmation shown before any radio write.
struct PresetConfirmView: View {
    let preset: MetroPreset
    var onApply: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Region", value: preset.regionName)
                LabeledContent("Modem preset", value: preset.presetName)
                if preset.frequencySlot > 0 {
                    LabeledContent("Frequency slot", value: "\(preset.frequencySlot)")
                }
                LabeledContent("Hop limit", value: "\(preset.hopLimit)")
            } header: {
                Text("This will be written to your radio")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your radio will restart to apply these settings; Hops reconnects automatically.")
                    if let source = preset.source, let url = URL(string: source) {
                        Link("Community source", destination: url)
                    }
                }
            }
            Button {
                onApply()
            } label: {
                Text("Apply to Radio")
                    .frame(maxWidth: .infinity)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle(preset.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
