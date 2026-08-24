import SwiftUI
import SwiftData

/// Who reacted with what, and when — shown by tapping a message's reaction pill.
struct ReactionDetailsSheet: View {
    let tapbacks: [MessageEntity]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tapbacks.sorted(by: { $0.timestamp < $1.timestamp }), id: \.packetId) { tapback in
                    HStack(spacing: 12) {
                        MonogramAvatar(text: monogram(for: tapback.fromNum), isChannel: false, size: 36,
                                       imageData: node(for: tapback.fromNum)?.iconData)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(for: tapback.fromNum))
                            Text(tapback.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(tapback.text)
                            .font(.title3)
                    }
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func node(for num: Int64) -> NodeEntity? {
        try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
        ).first
    }

    private func name(for num: Int64) -> String {
        if num == RadioManager.shared.myNodeNum { return "You" }
        return node(for: num)?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: num))
    }

    private func monogram(for num: Int64) -> String {
        node(for: num)?.monogram ?? "?"
    }
}
