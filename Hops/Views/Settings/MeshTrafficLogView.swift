import SwiftUI
import SwiftData

/// Real-time log of decoded mesh traffic — updates live while connected.
struct MeshTrafficLogView: View {
    @EnvironmentObject private var radio: RadioManager
    @ObservedObject private var traffic = TrafficMonitor.shared
    @Query private var nodes: [NodeEntity]

    private var namesByNum: [Int64: String] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.num, $0.shortName) })
    }

    var body: some View {
        Group {
            if traffic.entries.isEmpty {
                ContentUnavailableView(
                    "No traffic yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(radio.state == .connected
                                      ? "Decoded packets appear here as the radio hears them."
                                      : "Connect to your radio to watch live mesh traffic.")
                )
            } else {
                List(traffic.entries) { entry in
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
                        if entry.snr != 0 || entry.hopsAway >= 0 {
                            HStack(spacing: 12) {
                                if entry.hopsAway >= 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.triangle.branch")
                                        Text(entry.hopsAway == 0 ? "Direct" : "\(entry.hopsAway) hop\(entry.hopsAway == 1 ? "" : "s")")
                                    }
                                }
                                if entry.snr != 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "waveform")
                                        Text(String(format: "%.1f dB", entry.snr))
                                    }
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                        }
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
                Text("\(traffic.meshPacketsHeard) heard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Plain-text export for bug reports (TODO 182): oldest first,
                // one line per entry, with the same fields the rows show.
                ShareLink(item: logText, preview: SharePreview("Mesh Traffic log")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(traffic.entries.isEmpty)
            }
        }
    }

    private var logText: String {
        let stamp = Date.FormatStyle(date: .numeric, time: .standard)
        let lines = traffic.entries.reversed().map { entry -> String in
            var line = "\(entry.date.formatted(stamp))  \(name(for: entry.fromNum))  [\(entry.portName)]  \(entry.summary)"
            if entry.hopsAway >= 0 { line += "  hops=\(entry.hopsAway)" }
            if entry.snr != 0 { line += String(format: "  snr=%.1f", entry.snr) }
            return line
        }
        let header = "Hops Mesh Traffic - node \(String(format: "!%08x", UInt32(truncatingIfNeeded: radio.myNodeNum))), firmware \(radio.firmwareVersion), \(traffic.meshPacketsHeard) heard"
        return ([header] + lines).joined(separator: "\n")
    }

    private func name(for num: Int64) -> String {
        if radio.isMine(num) { return num == radio.myNodeNum ? "You" : "You (\(radio.fleet.first { $0.nodeNum == num }?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: num))))" }
        if let short = namesByNum[num], !short.trimmingCharacters(in: .whitespaces).isEmpty {
            return short
        }
        return String(format: "!%08x", UInt32(truncatingIfNeeded: num))
    }
}
