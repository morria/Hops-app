import SwiftUI
import SwiftData

/// Create or edit a channel slot and write it to the radio.
struct ChannelEditorView: View {
    let index: Int32
    let existing: ChannelEntity?

    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var roleRaw: Int32 = 2
    @State private var psk = Data()
    @State private var showDisableConfirm = false
    @State private var showShare = false
    @State private var copiedKey = false
    @State private var keyInput = ""
    @State private var keyError: String?

    private var isPrimary: Bool { index == 0 }

    var body: some View {
        Form {
            Section {
                TextField("Channel name", text: $name)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, newValue in
                        while newValue.utf8.count > 11 {
                            name.removeLast()
                            return
                        }
                    }
            } header: {
                Text("Name")
            } footer: {
                Text(isPrimary
                     ? "The primary channel. A blank name uses the modem preset's default."
                     : "Up to 11 characters. Everyone on a channel needs the same name and key.")
            }

            Section {
                LabeledContent("Current", value: pskDescription)
                if !psk.isEmpty {
                    // The key itself, base64 like every Meshtastic app shows it,
                    // so it can be read out or pasted elsewhere (TODO 183).
                    LabeledContent("Key") {
                        Text(psk.base64EncodedString())
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                    }
                    Button {
                        UIPasteboard.general.string = psk.base64EncodedString()
                        copiedKey = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedKey = false }
                    } label: {
                        Label(copiedKey ? "Copied" : "Copy Key", systemImage: copiedKey ? "checkmark" : "doc.on.doc")
                    }
                }
                Button("Use Default Key (AQ==)") { psk = Data([1]) }
                Button("Generate Random 256-bit Key") {
                    psk = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                }
                Button("No Encryption") { psk = Data() }
            } header: {
                Text("Encryption key")
            }

            // A specific key, typed or pasted — the way people actually join
            // a friend's channel (TODO 185). Base64 as every Meshtastic app
            // shows it, or hex; 1, 16, or 32 bytes.
            Section {
                HStack {
                    TextField("Paste a key (base64 or hex)", text: $keyInput)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyTypedKey)
                    if keyInput.isEmpty, UIPasteboard.general.hasStrings {
                        Button {
                            keyInput = UIPasteboard.general.string ?? ""
                            applyTypedKey()
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Use This Key", action: applyTypedKey)
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Enter a key")
            } footer: {
                Text(keyError ?? "Someone sharing a channel with you will give you its key. It must match exactly.")
                    .foregroundStyle(keyError == nil ? Color.secondary : Color.red)
            }

            if existing != nil {
                Section {
                    Button {
                        showShare = true
                    } label: {
                        Label("Share This Channel…", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("An invite for just this channel. Whoever scans it keeps their own primary channel and radio settings.")
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Save to Radio")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Changing channels reconfigures your radio. Share the updated QR code so others can rejoin.")
            }

            if !isPrimary, existing != nil {
                Section {
                    Button("Remove Channel", role: .destructive) {
                        showDisableConfirm = true
                    }
                    .confirmationDialog("Remove this channel?", isPresented: $showDisableConfirm, titleVisibility: .visible) {
                        Button("Remove Channel", role: .destructive) {
                            radio.setChannel(index: index, name: "", roleRaw: 0, psk: Data())
                            dismiss()
                        }
                    } message: {
                        Text("The slot is disabled on your radio. Messages already received stay on this phone.")
                    }
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Channel" : "Edit Channel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ShareSingleChannelView(name: existing?.name ?? name, psk: existing?.psk ?? psk)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            if let existing {
                name = existing.name
                roleRaw = existing.roleRaw
                psk = existing.psk
            } else {
                psk = Data([1])   // default key for a new channel
                roleRaw = isPrimary ? 1 : 2
            }
        }
    }

    private func applyTypedKey() {
        let raw = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let data = Self.decodeKey(raw) else {
            keyError = "That doesn't look like a key. Expected base64 (like AQ==) or hex."
            return
        }
        guard [1, 16, 32].contains(data.count) else {
            keyError = "Keys are 1, 16, or 32 bytes; this one is \(data.count)."
            return
        }
        psk = data
        keyInput = ""
        keyError = nil
    }

    /// Accepts standard or URL-safe base64 (padding optional) and hex.
    static func decodeKey(_ raw: String) -> Data? {
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if raw.count % 2 == 0, raw.count >= 2,
           raw.unicodeScalars.allSatisfy(hexChars.contains),
           raw.count == 32 || raw.count == 64 || raw.count == 2 {
            var bytes = [UInt8]()
            var index = raw.startIndex
            while index < raw.endIndex {
                let next = raw.index(index, offsetBy: 2)
                guard let b = UInt8(raw[index..<next], radix: 16) else { return nil }
                bytes.append(b)
                index = next
            }
            return Data(bytes)
        }
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    // (share sheet below)

    private var pskDescription: String {
        switch psk.count {
        case 0: return "None (open)"
        case 1: return psk == Data([1]) ? "Default (AQ==)" : "1-byte key"
        case 16: return "128-bit"
        case 32: return "256-bit"
        default: return "\(psk.count * 8)-bit"
        }
    }

    private func save() {
        let role: Int32 = isPrimary ? 1 : (roleRaw == 0 ? 2 : roleRaw)
        radio.setChannel(index: index, name: name.trimmingCharacters(in: .whitespaces), roleRaw: role, psk: psk)
        dismiss()
    }
}

/// QR + link for one channel in add mode (TODO 183). Uses the channel as
/// saved on the radio, not the unsaved edits above it.
struct ShareSingleChannelView: View {
    let name: String
    let psk: Data
    @Environment(\.dismiss) private var dismiss

    private var url: String? { MeshURL.encodeSingle(name: name, psk: psk) }
    private var title: String { name.isEmpty ? "this channel" : "\"\(name)\"" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let url, let qr = MeshURL.qrImage(for: url) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    Text("Scan with Hops or any Meshtastic app to add \(title). Their primary channel and radio settings stay as they are.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !psk.isEmpty {
                        LabeledContent("Key") {
                            Text(psk.base64EncodedString())
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal)
                    }
                    ShareLink(item: URL(string: url)!) {
                        Label("Share Invite Link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    ContentUnavailableView("Nothing to share", systemImage: "qrcode")
                }
            }
            .padding()
            .navigationTitle("Share \(name.isEmpty ? "Channel" : name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
