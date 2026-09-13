import SwiftUI
import SwiftData

/// The fleet (docs/MULTI_RADIO.md): which radio is sending, which others are
/// attached, and the priority order the owner controls by dragging.
struct RadiosView: View {
    @EnvironmentObject private var radio: RadioManager
    @State private var showAdd = false
    @State private var editMode: EditMode = .inactive

    private var transmit: RadioManager.AttachedRadio? { radio.attached.first { $0.isTransmit } }

    var body: some View {
        List {
            Section {
                if let transmit {
                    attachedRow(transmit, headline: true)
                } else if radio.attached.isEmpty {
                    Label(radio.fleet.isEmpty ? "No radios added" : "No radio in range",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                }
                ForEach(radio.attached.filter { !$0.isTransmit }) { link in
                    attachedRow(link, headline: false)
                }
            } header: {
                Text("Attached now")
            } footer: {
                Text("Messages go out through the highest radio in your order that is attached. Every attached radio receives.")
            }

            Section {
                ForEach(radio.fleet) { entry in
                    NavigationLink {
                        RadioDetailView(nodeNum: entry.nodeNum)
                    } label: {
                        fleetRow(entry)
                    }
                }
                .onMove { from, to in
                    var order = radio.fleet.map(\.nodeNum)
                    order.move(fromOffsets: from, toOffset: to)
                    radio.reorderFleet(order)
                }
                Button {
                    showAdd = true
                } label: {
                    Label("Add Radio…", systemImage: "plus.circle")
                }
            } header: {
                Text("Your radios, in order")
            } footer: {
                Text("Drag to reorder. Each radio is its own identity on the mesh; people reply to the one they heard from. A radio you're not attached to keeps only its last 8–32 packets for you — keep another device attached to a stationary radio and its messages reach you through iCloud.")
            }
        }
        .navigationTitle("Radios")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if radio.fleet.count > 1 {
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            PairingView(mode: .addRadio)
        }
    }

    private func name(for nodeNum: Int64) -> String {
        radio.fleet.first { $0.nodeNum == nodeNum }?.displayName
            ?? (nodeNum > 0 ? String(format: "Radio !%08x", UInt32(truncatingIfNeeded: nodeNum)) : "New radio")
    }

    private func attachedRow(_ link: RadioManager.AttachedRadio, headline: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: headline ? "antenna.radiowaves.left.and.right" : "ear")
                .foregroundStyle(link.phase == .connected ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(for: link.nodeNum))
                    .font(headline ? .headline : .body)
                Text(headline ? "Sending and receiving" : "Receiving only")
                    + Text(link.phase == .connected ? "" : " · \(phaseText(link.phase))")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
            if let entry = radio.fleet.first(where: { $0.nodeNum == link.nodeNum }), entry.lastBattery >= 0 {
                Text(entry.lastBattery > 100 ? "Power" : "\(entry.lastBattery)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fleetRow(_ entry: MessageStore.RadioSnapshot) -> some View {
        let attached = radio.attached.first { $0.nodeNum == entry.nodeNum }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                HStack(spacing: 6) {
                    Text(locationLabel(entry.locationTag))
                    if let attached {
                        Text("· \(attached.isTransmit ? "sending" : phaseText(attached.phase))")
                    } else if let seen = entry.lastSeenAt {
                        Text("· seen \(seen, style: .relative) ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.lastBattery >= 0 {
                Text(entry.lastBattery > 100 ? "Power" : "\(entry.lastBattery)%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if attached != nil {
                Circle().fill(attached?.phase == .connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            }
        }
    }

    private func phaseText(_ phase: RadioLink.Phase) -> String {
        switch phase {
        case .armed: return "out of range"
        case .connecting: return "connecting"
        case .syncing: return "syncing"
        case .connected: return "attached"
        case .bondLost: return "needs re-pairing"
        }
    }

    static func locationLabel(_ tag: String) -> String {
        switch tag {
        case "home": return "Home"
        case "office": return "Office"
        case "mobile": return "Mobile"
        default: return "Other"
        }
    }
    private func locationLabel(_ tag: String) -> String { Self.locationLabel(tag) }
}

/// One fleet radio: nickname, where it lives, what we know about it, forget.
struct RadioDetailView: View {
    let nodeNum: Int64
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss
    @Query private var nodes: [NodeEntity]
    @State private var nickname = ""
    @State private var location = "other"
    @State private var confirmForget = false
    @State private var confirmRevoke = false

    private var entry: MessageStore.RadioSnapshot? { radio.fleet.first { $0.nodeNum == nodeNum } }
    private var attached: RadioManager.AttachedRadio? { radio.attached.first { $0.nodeNum == nodeNum } }

    /// Live from the node record (telemetry lands there first), else the
    /// fleet row's last known value.
    private var batteryLevel: Int? {
        if let live = nodes.first(where: { $0.num == nodeNum })?.batteryLevel, live >= 0 { return live }
        if let last = entry?.lastBattery, last >= 0 { return last }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Nickname (e.g. Home upstairs)", text: $nickname)
                    .onSubmit { radio.renameRadio(nodeNum, nickname: nickname) }
                Picker("Location", selection: $location) {
                    Text("Home").tag("home")
                    Text("Office").tag("office")
                    Text("Mobile").tag("mobile")
                    Text("Other").tag("other")
                }
                .onChange(of: location) { _, tag in radio.setRadioLocation(nodeNum, tag: tag) }
            } footer: {
                Text("Location only shapes suggestions — you can run any radio in any configuration.")
            }

            Section {
                LabeledContent("Battery") {
                    if let battery = batteryLevel {
                        HStack(spacing: 6) {
                            Image(systemName: battery > 100 ? "powerplug" : battery > 60 ? "battery.100" : battery > 25 ? "battery.50" : "battery.25")
                            Text(battery > 100 ? "Plugged in" : "\(battery)%")
                        }
                        .foregroundStyle(battery <= 25 ? Color.red : Color.secondary)
                        .fixedSize()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Node ID", value: String(format: "!%08x", UInt32(truncatingIfNeeded: nodeNum)))
                if let fw = entry?.firmware, !fw.isEmpty { LabeledContent("Firmware", value: "v\(fw)") }
                if let attached {
                    LabeledContent("Status", value: attached.isTransmit ? "Attached · sending" : "Attached · receiving")
                } else if let seen = entry?.lastSeenAt {
                    LabeledContent("Last attached", value: seen.formatted(.relative(presentation: .named)))
                }
            } header: {
                Text("Details")
            } footer: {
                Label("Holds only its last 8–32 packets for you while you're not attached.", systemImage: "exclamationmark.triangle")
            }

            RadioSuggestionsSection(nodeNum: nodeNum)

            Section {
                Button("Forget This Radio…", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget this radio?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget Radio", role: .destructive) {
                            radio.forget(radio: nodeNum)
                            dismiss()
                        }
                    } message: {
                        Text("Removes it from your fleet on every device. Messages stay. You can pair it again anytime.")
                    }
                Button("Forget & Revoke Keys…", role: .destructive) { confirmRevoke = true }
                    .confirmationDialog("Lost or stolen?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                        Button("Forget and Rotate Channel Keys", role: .destructive) {
                            radio.forgetAndRevoke(radio: nodeNum)
                            dismiss()
                        }
                    } message: {
                        Text("Forgets the radio and gives every channel with a custom key a new one, applied to your sending radio now. Your other radios will show as differing until you apply fleet settings. Community channels on the default key can't be revoked. Anyone else on a rotated channel needs the new QR.")
                    }
            }
        }
        .navigationTitle(entry?.displayName ?? "Radio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nickname = entry?.nickname ?? ""
            location = entry?.locationTag ?? "other"
        }
        .onDisappear {
            if nickname != (entry?.nickname ?? "") { radio.renameRadio(nodeNum, nickname: nickname) }
        }
    }
}

/// Fleet settings for one attached radio (docs/MULTI_RADIO.md §1.5): how it
/// differs from the fleet with one-tap apply, and *suggestions* for its
/// owner name and role — never applied on their own.
struct RadioSuggestionsSection: View {
    let nodeNum: Int64
    @EnvironmentObject private var radio: RadioManager
    @Query private var nodes: [NodeEntity]
    @State private var appliedSettings = false
    @State private var appliedName = false
    @State private var appliedRole = false

    private var attached: RadioManager.AttachedRadio? { radio.attached.first { $0.nodeNum == nodeNum } }
    private var entry: MessageStore.RadioSnapshot? { radio.fleet.first { $0.nodeNum == nodeNum } }

    var body: some View {
        if let attached, attached.phase == .connected {
            if !attached.isTransmit {
                Section {
                    if attached.drift.isEmpty || appliedSettings {
                        Label(appliedSettings ? "Fleet settings sent — the radio restarts" : "Matches the fleet",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(attached.drift, id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Button {
                            radio.applyFleetSettings(to: nodeNum)
                            appliedSettings = true
                        } label: {
                            Label("Apply Fleet Settings", systemImage: "arrow.down.doc")
                        }
                    }
                } header: {
                    Text("Fleet settings")
                } footer: {
                    Text("Channels, keys, region, preset, slot and hop limit as carried by your sending radio. Identity and security are never copied.")
                }
            }

            let role = roleSuggestion
            Section {
                if let suggestion = nameSuggestion {
                    LabeledContent("Suggested name") {
                        Text("\(suggestion.long) (\(suggestion.short))")
                            .multilineTextAlignment(.trailing)
                    }
                    Button(appliedName ? "Name sent" : "Use Suggested Name") {
                        radio.setOwner(longName: suggestion.long, shortName: suggestion.short, via: nodeNum)
                        appliedName = true
                    }
                    .disabled(appliedName)
                }
                LabeledContent("Suggested role") {
                    Text(role.label)
                }
                if let current = attached.roleRaw, current == role.raw || appliedRole {
                    Text(appliedRole ? "Role sent" : "Already set")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Apply Suggested Role") {
                        radio.setDeviceRole(role.raw, via: nodeNum)
                        appliedRole = true
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text(role.reason + " Only suggestions — any radio can run any configuration.")
            }
        } else {
            Section {
                Text("Attach this radio to see fleet settings and suggestions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "<base> · <Location>" / "<3 of base short><L>", from the fleet's first
    /// radio's names. None for the first radio itself.
    private var nameSuggestion: (long: String, short: String)? {
        guard let first = radio.fleet.first, first.nodeNum != nodeNum,
              let node = nodes.first(where: { $0.num == first.nodeNum }) else { return nil }
        var base = node.longName
        if let dot = base.range(of: " · ") { base = String(base[..<dot.lowerBound]) }
        base = base.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !MessageStore.isPlaceholderName(base) else { return nil }
        let location = RadiosView.locationLabel(entry?.locationTag ?? "other")
        let long = MeshName.clampLong("\(base) · \(location)")
        let shortBase = String(node.shortName.prefix(3))
        let short = MeshName.clampShort(shortBase + String(location.prefix(1)))
        return (long, short)
    }

    private var roleSuggestion: (raw: Int, label: String, reason: String) {
        let tag = entry?.locationTag ?? "other"
        let order = radio.fleet
        let myIndex = order.firstIndex { $0.nodeNum == nodeNum } ?? order.count
        let earlierSamePlace = order.prefix(myIndex).contains { $0.locationTag == tag && (tag == "home" || tag == "office") }
        switch tag {
        case "mobile":
            return (1, "Client Mute", "A radio that moves shouldn't relay for others; it would waste airtime and confuse routes.")
        case "home", "office":
            if earlierSamePlace {
                return (1, "Client Mute", "Another of your radios at this location already relays; a second one relaying doubles airtime.")
            }
            return (0, "Client", "A stationary radio can relay for its neighbours.")
        default:
            return (0, "Client", "The default role.")
        }
    }
}
