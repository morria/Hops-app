import SwiftUI
import SwiftData
import MapKit

/// The single node card, shared by the DM info button and the map's node panel:
/// identity, last heard, battery, hops, signal — plus Message and Directions.
struct NodeCardView: View {
    let nodeNum: Int64
    var onMessage: (() -> Void)? = nil

    @Query private var nodes: [NodeEntity]
    @Environment(\.dismiss) private var dismiss

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
                        HStack(spacing: 12) {
                            MonogramAvatar(text: node.monogram, isChannel: false, size: 56,
                                           dimmed: !node.isOnline, imageData: node.iconData)
                            VStack(alignment: .leading) {
                                Text(node.displayName).font(.headline)
                                if let heard = node.lastHeard {
                                    Text("Heard \(heard.formatted(.relative(presentation: .named)))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Never heard directly")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

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
                .navigationTitle("Node")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private func openInMaps(_ node: NodeEntity) {
        let placemark = MKPlacemark(coordinate: node.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = node.displayName
        item.openInMaps()
    }
}
