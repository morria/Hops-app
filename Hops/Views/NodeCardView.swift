import SwiftUI
import SwiftData
import MapKit
import PhotosUI
import CryptoKit

/// The single node card, shared by the DM info button and the map's node panel:
/// identity, last heard, battery, hops, signal — plus Message and Directions.
struct NodeCardView: View {
    let nodeNum: Int64
    var onMessage: (() -> Void)? = nil

    @Query private var nodes: [NodeEntity]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showRename = false
    @State private var renameText = ""
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
                    Section {
                        LabeledContent("Last heard",
                                       value: node.lastHeard.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")

                        if node.batteryLevel >= 0 {
                            LabeledContent("Battery",
                                           value: node.batteryLevel > 100 ? "Plugged in" : "\(node.batteryLevel)%")
                        }
                        if node.hopsAway >= 0 {
                            LabeledContent("Hops away", value: node.hopsAway == 0 ? "Direct" : "\(node.hopsAway)")
                        }
                        if node.snr != 0 {
                            LabeledContent("Signal (SNR)", value: String(format: "%.1f dB", node.snr))
                        }
                    }

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
                        if !node.publicKey.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Key fingerprint")
                                    .font(.subheadline)
                                Text(fingerprint(node.publicKey))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("Compare with the owner over another channel to verify.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("Security")
                    }

                    Section("Customize") {
                        Button {
                            renameText = node.customName
                            showRename = true
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Set Photo…", systemImage: "photo")
                        }
                        if node.iconData != nil {
                            Button(role: .destructive) {
                                setPhoto(nil, for: node)
                            } label: {
                                Label("Remove Photo", systemImage: "photo.badge.exclamationmark")
                            }
                        }
                    }

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
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // The node itself is the title: avatar + name, no "Node" label.
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            MonogramAvatar(text: node.monogram, isChannel: false, size: 26,
                                           dimmed: !node.isOnline, imageData: node.iconData)
                            Text(node.displayName)
                                .font(.headline)
                                .lineLimit(1)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .alert("Rename", isPresented: $showRename) {
                    TextField("Name", text: $renameText)
                    Button("Save") { applyRename(node) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Shown only on your devices. Leave blank to use the name from the mesh.")
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
            }
        }
    }

    private func applyRename(_ node: NodeEntity) {
        node.customName = renameText.trimmingCharacters(in: .whitespaces)
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

    /// Human-comparable digest of the peer's public key (SHA-256, grouped hex).
    private func fingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    private func openInMaps(_ node: NodeEntity) {
        let placemark = MKPlacemark(coordinate: node.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = node.displayName
        item.openInMaps()
    }
}
