import SwiftUI
import SwiftData
import MapKit

struct MapTab: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel
    @Query private var nodes: [NodeEntity]
    @Query private var waypoints: [WaypointEntity]

    @State private var selectedNodeNum: Int64?
    @State private var position: MapCameraPosition = .automatic

    private var placedNodes: [NodeEntity] {
        nodes.filter { $0.hasPosition && $0.num != radio.myNodeNum }
    }

    private var activeWaypoints: [WaypointEntity] {
        waypoints.filter { $0.expires == nil || $0.expires! > Date() }
    }

    private struct PlacedNode {
        let node: NodeEntity
        let coordinate: CLLocationCoordinate2D
    }

    /// Nodes sharing a coordinate (common with precision-fuzzed positions, which
    /// snap to a grid) are spread on a small deterministic ring — ordered by node
    /// number, so the layout is stable — keeping every pin tappable. Isolated
    /// nodes stay exactly where reported; precision circles always stay true.
    private var displayNodes: [PlacedNode] {
        let groups = Dictionary(grouping: placedNodes) { node in
            "\((node.latitude * 10_000).rounded()):\((node.longitude * 10_000).rounded())"
        }
        var placed: [PlacedNode] = []
        for members in groups.values {
            guard members.count > 1 else {
                placed.append(PlacedNode(node: members[0], coordinate: members[0].coordinate))
                continue
            }
            let sorted = members.sorted { $0.num < $1.num }
            for (index, node) in sorted.enumerated() {
                let angle = 2 * Double.pi * Double(index) / Double(sorted.count)
                // Fuzzed nodes may honestly sit anywhere in their circle; use a
                // fraction of it (capped), with a 40 m floor for exact stacks.
                let fuzzed = node.precisionBits > 0 && node.precisionBits < 32
                let radius = fuzzed ? min(max(40, node.precisionRadius * 0.2), 200) : 40
                let dLat = radius * cos(angle) / 111_111.0
                let dLon = radius * sin(angle) / (111_111.0 * cos(node.latitude * .pi / 180))
                placed.append(PlacedNode(node: node, coordinate: CLLocationCoordinate2D(
                    latitude: node.latitude + dLat, longitude: node.longitude + dLon)))
            }
        }
        return placed
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                ForEach(displayNodes, id: \.node.num) { placed in
                    let node = placed.node
                    // Fuzzed positions render as a precision circle, never a false pin.
                    if node.precisionBits > 0 && node.precisionBits < 32 {
                        MapCircle(center: node.coordinate, radius: node.precisionRadius)
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                    }
                    Annotation(node.shortName, coordinate: placed.coordinate) {
                        Button {
                            selectedNodeNum = node.num
                        } label: {
                            MonogramAvatar(text: node.monogram, isChannel: false, size: 32, dimmed: !node.isOnline)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(activeWaypoints) { waypoint in
                    Annotation(waypoint.name, coordinate: CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)) {
                        Text(waypoint.icon)
                            .font(.title3)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedNodeNum) { num in
                NodeCardView(nodeNum: num) {
                    selectedNodeNum = nil
                    appModel.openConversation(ConversationEntity.dmKey(num))
                }
                .presentationDetents([.medium])
            }
            .overlay {
                if placedNodes.isEmpty {
                    ContentUnavailableView(
                        "No positions yet",
                        systemImage: "map",
                        description: Text("Nodes appear here once they share a location over the mesh.")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

extension Int64: @retroactive Identifiable {
    public var id: Int64 { self }
}

extension NodeEntity {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Approximate metres of uncertainty for a fuzzed position (halves per bit).
    var precisionRadius: CLLocationDistance {
        23_905_787.925 * pow(0.5, Double(precisionBits))
    }
}

