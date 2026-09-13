import SwiftUI
import SwiftData
import MeshtasticProtobufs

/// One-row query for the local node (TODO 188). SettingsView used to hold an
/// all-nodes @Query and scan it on every render — and it re-rendered on every
/// radio change, in the background too, until iOS killed the app for CPU.
private struct MyNodeSummary<Content: View>: View {
    @Query private var nodes: [NodeEntity]
    private let content: (NodeEntity?) -> Content

    init(num: Int64, @ViewBuilder content: @escaping (NodeEntity?) -> Content) {
        _nodes = Query(filter: #Predicate<NodeEntity> { $0.num == num })
        self.content = content
    }

    var body: some View { content(nodes.first) }
}

/// The "Mesh traffic" summary row observes the per-packet monitor alone, so
/// packets re-render this one row and not the whole Settings screen.
private struct TrafficSummaryRow: View {
    @ObservedObject private var traffic = TrafficMonitor.shared

    var body: some View {
        LabeledContent("Mesh traffic") {
            Text(description)
                .foregroundStyle(traffic.meshPacketsHeard == 0 ? .orange : .secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var description: String {
        if traffic.meshPacketsHeard == 0 {
            return "None heard since launch"
        }
        // Compact on purpose — "15 seconds ago" wraps the row.
        var text = "\(traffic.meshPacketsHeard) pkts · \(traffic.textMessagesHeard) msgs"
        if let last = traffic.lastMeshPacketAt {
            text += " · \(SettingsView.compactAgo(last))"
        }
        return text
    }
}

struct SettingsView: View {
    @EnvironmentObject private var radio: RadioManager

    @AppStorage("notifyDMs") private var notifyDMs = true
    @AppStorage("notifyChannels") private var notifyChannels = true
    @AppStorage("useFahrenheit") private var useFahrenheit = Locale.current.measurementSystem != .metric
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @State private var showForgetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                radioSection
                onMeshSection
                notificationsSection
                appSection
                #if MESHSITES
                meshsitesSection
                experimentalSection
                #endif
                advancedSection
                aboutSection
            }
            .environment(\.editMode, $radioEditMode)
            .sheet(isPresented: $showAddRadio) { PairingView(mode: .addRadio) }
            .navigationTitle("Settings")
            .toolbar {
                if radio.fleet.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
            .refreshable {
                await radio.refreshDeviceStatus()
            }
        }
    }

    // MARK: - Radio

    @State private var radioEditMode: EditMode = .inactive
    @State private var showAddRadio = false

    private var radioSection: some View {
        Group {
            Section {
                if radio.fleet.isEmpty {
                    Button("Pair a Radio…") {
                        onboardingComplete = false   // reopens the guided pairing flow
                    }
                } else {
                    ForEach(radio.fleet) { entry in
                        fleetRow(entry)
                    }
                    .onMove { from, to in
                        var order = radio.fleet.map(\.nodeNum)
                        order.move(fromOffsets: from, toOffset: to)
                        radio.reorderFleet(order)
                    }
                    Button {
                        showAddRadio = true
                    } label: {
                        Label("Add Radio…", systemImage: "plus.circle")
                    }
                }
                if !radio.fleet.isEmpty {
                    NavigationLink {
                        MeshSetupView(isFirstRun: false)
                    } label: {
                        LabeledContent(radio.fleet.count > 1 ? "Mesh setup · \(sendingRadioName)" : "Mesh setup") {
                            Text(radio.loRa.received
                                 ? "\(radio.loRa.regionName) · \(radio.loRa.presetName)"
                                 : "—")
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
                }
            } header: {
                Text("Radios")
            } footer: {
                if radio.fleet.count > 1 {
                    Text("The top radio in range sends and receives; every other radio in range only receives. Use Edit to drag them into order. Tap a radio for its configuration.")
                } else if !radio.fleet.isEmpty {
                    Text("Tap the radio for its configuration. Add more and drag them into the order you want to send from.")
                }
            }
        }
    }

    private var sendingRadioName: String {
        radio.fleet.first { $0.nodeNum == radio.myNodeNum }?.displayName ?? "the sending radio"
    }

    /// One fleet radio as a Settings row: name, what it's doing, battery.
    /// Attached → its Device Configuration; otherwise its detail page.
    @ViewBuilder
    private func fleetRow(_ entry: MessageStore.RadioSnapshot) -> some View {
        let link = radio.attached.first { $0.nodeNum == entry.nodeNum }
        let connected = link?.phase == .connected
        let detached = radio.userDisconnectedRadios.contains(entry.nodeNum)
        NavigationLink {
            if connected { DeviceConfigurationView(nodeNum: entry.nodeNum) } else { RadioDetailView(nodeNum: entry.nodeNum) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: link?.isTransmit == true ? "antenna.radiowaves.left.and.right" : (connected ? "ear" : "antenna.radiowaves.left.and.right.slash"))
                    .foregroundStyle(connected ? (link?.isTransmit == true ? Color.green : Color.blue) : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                    Text(fleetStatus(link: link, detached: detached, entry: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.lastBattery >= 0 {
                    Label(entry.lastBattery > 100 ? "Power" : "\(entry.lastBattery)%", systemImage: batteryIcon(entry.lastBattery))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
            }
        }
    }

    private func fleetStatus(link: RadioManager.AttachedRadio?, detached: Bool, entry: MessageStore.RadioSnapshot) -> String {
        if detached { return "Disconnected by you" }
        guard let link else {
            if radio.state == .bluetoothOff { return "Bluetooth is off" }
            if let seen = entry.lastSeenAt { return "Out of range · seen \(Self.compactAgo(seen))" }
            return "Out of range"
        }
        switch link.phase {
        case .connected:
            var text = link.isTransmit ? "Sending & receiving" : "Receiving only"
            if let c = radio.configsByNode[entry.nodeNum] {
                if c.lora?.txEnabled == false { text = "Transmit off · listening only" }
                if c.power?.isPowerSaving == true { text += " · sleeps (Bluetooth off)" }
            }
            return text
        case .syncing: return "Syncing…"
        case .connecting: return "Connecting…"
        case .bondLost: return "Needs re-pairing"
        case .armed: return "Out of range"
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

    fileprivate static func compactAgo(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
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

    private var onMeshSection: some View {
        Section("Identity") {
            NavigationLink {
                IdentityView()
            } label: {
                MyNodeSummary(num: radio.myNodeNum) { myNode in
                    LabeledContent(radio.fleet.count > 1 ? "Your name on \(sendingRadioName)" : "Your name",
                                   value: myNode.map { "\($0.longName) (\($0.shortName))" } ?? "Not set")
                }
                .id(radio.myNodeNum)
            }
            NavigationLink {
                ChannelsView()
            } label: {
                Label("Channels & QR codes", systemImage: "qrcode")
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Direct messages", isOn: $notifyDMs)
            Toggle("Messages in channels", isOn: $notifyChannels)
            Button("iOS Notification Settings…") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Per-conversation control (mute, mentions only) is a long-press on the conversation in Chats. Turning notifications off entirely lives in iOS Settings, like any app.")
        }
    }

    // MARK: - Units

    private var appSection: some View {
        Section {
            Picker("Temperature", selection: $useFahrenheit) {
                Text("°F").tag(true)
                Text("°C").tag(false)
            }
            Toggle("Battery Saver", isOn: $batterySaver)
        } header: {
            Text("App")
        } footer: {
            Text("Battery Saver pauses coverage sampling and Live Activities, slows map refresh, and skips the reconnect scan boost (reconnects still happen, slightly slower). Messaging is unaffected. Engages automatically with iOS Low Power Mode.")
        }
    }

    // MARK: - Battery

    @AppStorage("batterySaver") private var batterySaver = false

    #if MESHSITES
    @AppStorage("meshsitesEnabled") private var meshsitesEnabled = false

    private var meshsitesSection: some View {
        Section {
            Toggle("Meshsites", isOn: $meshsitesEnabled)
            if meshsitesEnabled {
                NavigationLink {
                    MySiteView()
                } label: {
                    Label("Mesh Site", systemImage: "house")
                }
            }
        } header: {
            Text("Meshsites")
        } footer: {
            Text("Tiny pages served by nearby radios over direct contact — no internet, no relays. Turn it on to browse them and to host your own.")
        }
    }
    #endif

    // MARK: - Experimental

    @AppStorage("gamesEnabled") private var gamesEnabled = false

    private var experimentalSection: some View {
        Section {
            Toggle("Games", isOn: $gamesEnabled)
        } header: {
            Text("Experimental")
        } footer: {
            Text("Two-player games with another Hops user over the mesh — chess, checkers, and more. Adds a Games tab. Each move is confirmed by both phones before it counts.")
        }
    }

    // MARK: - Node retention

    @AppStorage("nodeMaxAgeDays") private var nodeMaxAgeDays = 90
    @AppStorage("sequenceTrailerEnabled") private var sequenceTrailerEnabled = true

    private var advancedSection: some View {
        Section {
            NavigationLink {
                MeshTrafficLogView()
            } label: {
                TrafficSummaryRow()
            }
            Picker("Remove unheard nodes after", selection: $nodeMaxAgeDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("Never").tag(0)
            }
            .onChange(of: nodeMaxAgeDays) {
                radio.applyNodeRetention()
            }
            Toggle("Sequence numbers on sends", isOn: $sequenceTrailerEnabled)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Renamed, photographed, or messaged nodes are always kept.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            Link(destination: URL(string: "https://github.com/morria/Hops-app")!) {
                Label("Hops on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://meshtastic.org")!) {
                Text("Meshtastic Project")
            }
            Text("Hops is an independent client for Meshtastic® radios. Meshtastic® is a registered trademark of Meshtastic LLC. For device administration — modules, firmware, remote nodes — use the official Meshtastic app; both work with the same radio.")
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
                    .onChange(of: longName) { _, newValue in
                        longName = MeshName.clampLong(newValue)
                    }
                TextField("Short name (4 characters)", text: $shortName)
                    .onChange(of: shortName) { _, newValue in
                        shortName = MeshName.clampShort(newValue)
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How you appear to everyone on the mesh. The short name is your map marker and channel tag: up to 4 letters, or one plain emoji.")
                    if let note = MeshName.budgetNote(long: longName, short: shortName) {
                        Text(note)
                    }
                }
            }
            Button("Save") {
                // RadioManager mirrors the names locally (and reverts on NAK).
                radio.setOwner(longName: longName, shortName: shortName)
                dismiss()
            }
            .disabled(longName.trimmingCharacters(in: .whitespaces).isEmpty
                      || shortName.trimmingCharacters(in: .whitespaces).isEmpty
                      || !MeshName.fitsLong(longName) || !MeshName.fitsShort(shortName))

            if radio.myNodeNum > 0 {
                Section {
                    LabeledContent("Node ID") {
                        Text(String(format: "!%08x", UInt32(truncatingIfNeeded: radio.myNodeNum)))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Node number") {
                        Text("\(UInt32(truncatingIfNeeded: radio.myNodeNum))")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Your ID")
                } footer: {
                    Text("How the mesh addresses your radio. Searchable by other Hops users; useful when correlating server or firmware logs.")
                }
            }

            if let key = nodes.first(where: { $0.num == radio.myNodeNum })?.publicKey, !key.isEmpty {
                Section {
                    KeyFingerprintView(key: key)
                } header: {
                    Text("Your key fingerprint")
                } footer: {
                    Text("This is what others see on your node card. Read it to each other over another channel to verify your DMs are end-to-end encrypted with the right person.")
                }
            }
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
    /// Which fleet radio to write; nil = the sending radio.
    var nodeNum: Int64? = nil

    @EnvironmentObject private var radio: RadioManager
    @StateObject private var presets = MetroPresetStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var confirming: MetroPreset?
    @State private var showSaveCustom = false
    @State private var customName = ""
    // Passive only — never prompts. If location is already authorized, the
    // local metro's preset sorts to the top with a "Near you" badge.
    @State private var here: (lat: Double, lon: Double)?

    private var orderedPresets: [MetroPreset] {
        guard let here else { return presets.allPresets }
        return presets.allPresets.sorted {
            let a = $0.covers(latitude: here.lat, longitude: here.lon)
            let b = $1.covers(latitude: here.lat, longitude: here.lon)
            return a && !b
        }
    }

    private func isNearby(_ preset: MetroPreset) -> Bool {
        guard let here else { return false }
        return preset.covers(latitude: here.lat, longitude: here.lon)
    }

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
                ForEach(orderedPresets) { preset in
                    Button {
                        confirming = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(preset.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                if isNearby(preset) {
                                    Text("Near you")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
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
        .task {
            // Passive: only when already authorized — Mesh Setup must never
            // be the thing that triggers a location prompt.
            guard LocationProvider.shared.isAuthorized,
                  let fix = await LocationProvider.shared.current() else { return }
            here = (fix.coordinate.latitude, fix.coordinate.longitude)
        }
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
                                          metroPresetId: preset.id, via: nodeNum)
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
