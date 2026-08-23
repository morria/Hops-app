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

            Section("Encryption key") {
                LabeledContent("Current", value: pskDescription)
                Button("Use Default Key (AQ==)") { psk = Data([1]) }
                Button("Generate Random 256-bit Key") {
                    psk = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                }
                Button("No Encryption") { psk = Data() }
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
