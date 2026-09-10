import SwiftUI
import SwiftData
import MeshtasticProtobufs

struct ChannelsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Query(sort: \ChannelEntity.index) private var channels: [ChannelEntity]

    @State private var showScanner = false
    @State private var showShare = false
    @State private var pendingImport: MeshURL.Link?
    @State private var importFailed = false

    var body: some View {
        List {
            Section("This radio's channels") {
                if channels.filter({ $0.isActive }).isEmpty {
                    Text("No channels yet — they appear after the first sync.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(channels.filter { $0.isActive }) { channel in
                        NavigationLink {
                            ChannelEditorView(index: channel.index, existing: channel)
                        } label: {
                            HStack {
                                MonogramAvatar(text: "#", isChannel: true, size: 32,
                                               assetImage: MetroPresetStore.shared.channelIconAsset(forChannelIndex: channel.index),
                                               imageData: channel.iconData)
                                Text(channel.displayName)
                                Spacer()
                                if !channel.psk.isEmpty {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let free = firstFreeIndex {
                    NavigationLink {
                        ChannelEditorView(index: free, existing: nil)
                    } label: {
                        Label("Add Channel", systemImage: "plus.circle")
                    }
                }
            }
            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("Join a Mesh — Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                Button {
                    importFromPasteboard()
                } label: {
                    Label("Join from Copied Link", systemImage: "link")
                }
                Button {
                    showShare = true
                } label: {
                    Label("Share My Channels", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("A channel QR code or meshtastic.org link is how a mesh community shares its working setup — channels, keys, and radio settings together.")
            }
        }
        .navigationTitle("Channels")
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { code in
                    showScanner = false
                    handleImport(code)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Channel QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareChannelsView()
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { pendingImport.map(ImportBox.init) },
            set: { pendingImport = $0?.link }
        )) { box in
            NavigationStack {
                ImportConfirmView(link: box.link, freeSlots: freeSlots) {
                    if box.link.add {
                        // Append to free slots; never touch the primary or LoRa.
                        for (settings, slot) in zip(box.link.channelSet.settings, freeSlots) {
                            radio.setChannel(index: slot, name: settings.name, roleRaw: 2, psk: settings.psk)
                        }
                    } else {
                        radio.applyChannelSet(box.link.channelSet)
                    }
                    pendingImport = nil
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Couldn't read that code", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It doesn't look like a Meshtastic channel QR code or link.")
        }
    }

    /// Unused channel slots, lowest first (radios support indexes 0–7).
    private var freeSlots: [Int32] {
        let used = Set(channels.filter { $0.roleRaw != 0 }.map { $0.index })
        return (Int32(0)...7).filter { !used.contains($0) }
    }

    private var firstFreeIndex: Int32? { freeSlots.first }

    private func importFromPasteboard() {
        guard let string = UIPasteboard.general.string else {
            importFailed = true
            return
        }
        handleImport(string)
    }

    private func handleImport(_ string: String) {
        if let link = MeshURL.parseLink(string), !link.channelSet.settings.isEmpty {
            pendingImport = link
        } else {
            importFailed = true
        }
    }
}

private struct ImportBox: Identifiable {
    let link: MeshURL.Link
    var id: String {
        ((try? link.channelSet.serializedData())?.base64EncodedString() ?? UUID().uuidString) + (link.add ? "+add" : "")
    }
}

/// One-screen confirmation before a QR/link import writes to the radio — a channel
/// QR contains LoRa settings, so the diff is shown, never silently applied.
struct ImportConfirmView: View {
    let link: MeshURL.Link
    var freeSlots: [Int32] = []
    var onApply: () -> Void

    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    private var channelSet: ChannelSet { link.channelSet }
    private var addLines: [String] {
        zip(channelSet.settings, freeSlots).map { settings, slot in
            "Adds \(settings.name.isEmpty ? "an unnamed channel" : "\"\(settings.name)\"")\(settings.psk.isEmpty ? "" : " (encrypted)") in slot \(slot)"
        } + (channelSet.settings.count > freeSlots.count ? ["Not enough free slots for every channel (radios hold 8)"] : [])
    }

    var body: some View {
        List {
            Section {
                ForEach(link.add ? addLines : MeshURL.describeImport(channelSet, current: radio.loRa), id: \.self) { line in
                    Text(line)
                }
            } header: {
                Text(link.add ? "Adding a channel" : "Joining applies these settings")
            } footer: {
                Text(link.add
                     ? "Your primary channel and radio settings are not changed."
                     : "If radio settings change, your radio restarts; Hops reconnects automatically.")
            }
            Button {
                onApply()
                dismiss()
            } label: {
                Text(link.add ? (channelSet.settings.count == 1 ? "Add Channel" : "Add Channels") : "Join Mesh")
                    .frame(maxWidth: .infinity)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle("Join Mesh")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

struct ShareChannelsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Query(sort: \ChannelEntity.index) private var channels: [ChannelEntity]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let url = shareURL, let qr = MeshURL.qrImage(for: url) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    Text("Scan with Hops or any Meshtastic app to join this mesh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ShareLink(item: URL(string: url)!) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    ContentUnavailableView("Nothing to share yet", systemImage: "qrcode",
                                           description: Text("Channels appear after the first sync with your radio."))
                }
            }
            .padding()
            .navigationTitle("Share Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var shareURL: String? {
        let active = channels.filter { $0.isActive }
        guard !active.isEmpty else { return nil }
        var channelSet = ChannelSet()
        for channel in active.sorted(by: { $0.index < $1.index }) {
            var settings = ChannelSettings()
            settings.name = channel.name
            settings.psk = channel.psk
            channelSet.settings.append(settings)
        }
        if radio.loRa.received {
            var lora = Config.LoRaConfig()
            lora.usePreset = true
            lora.region = Config.LoRaConfig.RegionCode(rawValue: radio.loRa.regionRaw) ?? .unset
            lora.modemPreset = Config.LoRaConfig.ModemPreset(rawValue: radio.loRa.presetRaw) ?? .longFast
            lora.channelNum = UInt32(radio.loRa.frequencySlot)
            lora.hopLimit = UInt32(radio.loRa.hopLimit)
            channelSet.loraConfig = lora
        }
        return MeshURL.encode(channelSet)
    }
}
