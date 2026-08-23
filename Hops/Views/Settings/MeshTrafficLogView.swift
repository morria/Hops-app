import SwiftUI
import SwiftData

/// Real-time log of decoded mesh traffic — updates live while connected.
struct MeshTrafficLogView: View {
    @EnvironmentObject private var radio: RadioManager
    @Query private var nodes: [NodeEntity]

    private var namesByNum: [Int64: String] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.num, $0.shortName) })
    }

    var body: some View {
        Group {
            if radio.trafficLog.isEmpty {
                ContentUnavailableView(
                    "No traffic yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(radio.state == .connected
                                      ? "Decoded packets appear here as the radio hears them."
                                      : "Connect to your radio to watch live mesh traffic.")
                )
            } else {
                List(radio.trafficLog) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name(for: entry.fromNum))
                                .font(.subheadline.weight(.semibold))
                            Text(entry.portName)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Mesh Traffic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(radio.meshPacketsHeard) heard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func name(for num: Int64) -> String {
        if num == radio.myNodeNum { return "You" }
        if let short = namesByNum[num], !short.trimmingCharacters(in: .whitespaces).isEmpty {
            return short
        }
        return String(format: "!%08x", UInt32(truncatingIfNeeded: num))
    }
}
