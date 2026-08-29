import SwiftUI
import SwiftData
import MapKit
import PhotosUI
import CryptoKit

/// The single node card, shared by the DM title button and the map's node
/// panel. Contact-card shape: identity header, actions, then reachability →
/// security → customize → details, in order of how often each is needed.
struct NodeCardView: View {
    let nodeNum: Int64
    var onMessage: (() -> Void)? = nil

    @Query private var nodes: [NodeEntity]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showKeyResetConfirm = false
    @State private var customNameDraft = ""
    @State private var seededDraft = false
    @EnvironmentObject private var radio: RadioManager
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropImage: CropImageBox?

    struct CropImageBox: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    init(nodeNum: Int64, onMessage: (() -> Void)? = nil) {
        self.nodeNum = nodeNum
        self.onMessage = onMessage
        let num = nodeNum
        _nodes = Query(filter: #Predicate<NodeEntity> { $0.num == num })
    }

    var body: some View {
        NavigationStack {
            if let node = nodes.first {
                List {
                    headerSection(node)
                    actionsSection(node)
                    reachabilitySection(node)
                    securitySection(node)
                    customizeSection(node)
                    detailsSection(node)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            commitRename(node)
                            dismiss()
                        }
                    }
                }
                .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
                .onChange(of: pickedPhoto) { _, item in
                    guard let item else { return }
                    pickedPhoto = nil
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            cropImage = CropImageBox(image: image)
                        }
                    }
                }
                .sheet(item: $cropImage) { box in
                    AvatarCropView(image: box.image) { cropped in
                        setPhoto(cropped.jpegData(compressionQuality: 0.85), for: node)
                    }
                }
                .onAppear {
                    if !seededDraft {
                        customNameDraft = node.customName
                        seededDraft = true
                    }
                }
            }
        }
    }

    // MARK: - Header (who this is)

    private func headerSection(_ node: NodeEntity) -> some View {
        Section {
            VStack(spacing: 8) {
                // Never dimmed here: the presence line below is the explicit
                // liveness signal, and a faded photo reads as a broken image.
                MonogramAvatar(text: node.monogram, isChannel: false, size: 76,
                               imageData: node.iconData)
                Text(node.displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                // The mesh identity is always visible — it's what everyone
                // else sees, and the anchor when a custom name is set.
                Text("\(node.shortName) · \(node.longName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                presenceLine(node)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        }
    }

    @ViewBuilder
    private func presenceLine(_ node: NodeEntity) -> some View {
        HStack(spacing: 6) {
            switch radio.presence[node.num] {
            case .reachable(let at):
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Reachable · \(at.formatted(.relative(presentation: .named)))")
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking…")
            case .noResponse:
                Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("Not responding")
            case nil:
                Image(systemName: "circle.dotted").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text("Presence unknown")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions (right under the identity, contact-card style)

    @ViewBuilder
    private func actionsSection(_ node: NodeEntity) -> some View {
        if onMessage != nil || node.hasPosition {
            Section {
                HStack(spacing: 12) {
                    if let onMessage, node.isMessageable {
                        Button {
                            onMessage()
                        } label: {
                            Label("Message", systemImage: "bubble.left.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    if node.hasPosition {
                        Button {
                            openInMaps(node)
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .buttonBorderShape(.capsule)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    // MARK: - Reachability (the questions asked most often)

    private func reachabilitySection(_ node: NodeEntity) -> some View {
        Section {
            LabeledContent("Last heard",
                           value: node.lastHeard.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            if node.hopsAway >= 0 {
                LabeledContent("Hops away", value: node.hopsAway == 0 ? "Direct" : "\(node.hopsAway)")
            }
            if let probe = radio.lastProbe[node.num] {
                LabeledContent("Last probe",
                               value: probe.sentAt.formatted(.relative(presentation: .named)))
                if let replied = probe.respondedAt {
                    LabeledContent("Replied",
                                   value: String(format: "in %.0f s", replied.timeIntervalSince(probe.sentAt)))
                    if let hops = probe.replyHops {
                        LabeledContent("Reply hops", value: hops == 0 ? "Direct" : "\(hops)")
                    }
                } else if case .checking = radio.presence[node.num] {
                    LabeledContent("Reply") {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Waiting…")
                        }
                    }
                } else {
                    LabeledContent("Reply", value: "None (45 s)")
                }
            }
            Button {
                radio.probePresence(node.num, force: true)
            } label: {
                Label("Probe Now", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled({ if case .checking = radio.presence[node.num] { return true }; return false }())
        } header: {
            Text("Reachability")
        } footer: {
            Text("A probe asks their radio directly — it replies even without an app running. Any packet from them counts as the reply.")
        }
    }

    // MARK: - Security

    private func securitySection(_ node: NodeEntity) -> some View {
        Section {
            if node.keyChanged {
                Label {
                    Text("This node's encryption key changed since it was first seen. Verify with the owner before trusting messages — a changed key can mean a reflashed radio, or an impersonator.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("Encryption") {
                if node.publicKey.isEmpty {
                    Text("Channel key only")
                } else {
                    Label("End-to-end (PKI)", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(node.keyChanged ? .orange : .green)
                }
            }
            LabeledContent("Node ID") {
                Text(String(format: "!%08x", UInt32(truncatingIfNeeded: node.num)))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if !node.publicKey.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Key fingerprint")
                        .font(.subheadline)
                    KeyFingerprintView(key: node.publicKey)
                    Text("Compare with the owner over another channel to verify.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(role: .destructive) {
                    showKeyResetConfirm = true
                } label: {
                    Label("Reset Encryption Key…", systemImage: "key.slash")
                }
                .confirmationDialog(
                    "Reset this node's encryption key?",
                    isPresented: $showKeyResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset Key", role: .destructive) {
                        node.publicKey = Data()
                        node.keyChanged = false
                    }
                } message: {
                    Text("Forgets the pinned key so the next announcement from this node is trusted. Do this only when you know why the key changed — for example, the owner reflashed their radio. Until it re-announces, messages fall back to channel encryption.")
                }
            }
        } header: {
            Text("Security")
        }
    }

    // MARK: - Customize (inline editors, settings-style)

    private func customizeSection(_ node: NodeEntity) -> some View {
        Section {
            // Inline rename: commits on return or when the sheet closes.
            TextField(node.longName, text: $customNameDraft)
                .onSubmit { commitRename(node) }
                .submitLabel(.done)
            Button {
                showPhotoPicker = true
            } label: {
                Label(node.iconData == nil ? "Set Photo…" : "Change Photo…", systemImage: "photo")
            }
            if node.iconData != nil {
                Button(role: .destructive) {
                    setPhoto(nil, for: node)
                } label: {
                    Label("Remove Photo", systemImage: "photo.badge.exclamationmark")
                }
            }
        } header: {
            Text("Custom Name & Photo")
        } footer: {
            Text("Shown only on your devices. Clear the name to use theirs from the mesh.")
        }
    }

    // MARK: - Details (everything else)

    private func detailsSection(_ node: NodeEntity) -> some View {
        Section("Details") {
            LabeledContent("Mesh short name", value: node.shortName)
            LabeledContent("Mesh long name", value: node.longName)
            LabeledContent("Node number") {
                Text("\(UInt32(truncatingIfNeeded: node.num))")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if node.batteryLevel >= 0 {
                LabeledContent("Battery",
                               value: node.batteryLevel > 100 ? "Plugged in" : "\(node.batteryLevel)%")
            }
            if node.snr != 0 {
                LabeledContent("Signal (SNR)", value: String(format: "%.1f dB", node.snr))
            }
        }
    }

    // MARK: - Helpers

    private func commitRename(_ node: NodeEntity) {
        let trimmed = customNameDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != node.customName else { return }
        node.customName = trimmed
        syncConversationTitle(for: node)
    }

    private func setPhoto(_ data: Data?, for node: NodeEntity) {
        node.iconData = data
        try? modelContext.save()
    }

    private func syncConversationTitle(for node: NodeEntity) {
        let key = ConversationEntity.dmKey(node.num)
        if let convo = try? modelContext.fetch(
            FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.key == key })
        ).first {
            convo.title = node.displayName
        }
        try? modelContext.save()
    }

    private func openInMaps(_ node: NodeEntity) {
        let placemark = MKPlacemark(coordinate: node.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = node.displayName
        item.openInMaps()
    }
}
