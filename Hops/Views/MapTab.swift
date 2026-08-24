import SwiftUI
import SwiftData
import MapKit

struct MapTab: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel
    @Query private var nodes: [NodeEntity]
    @Query private var waypoints: [WaypointEntity]
    @Query private var trailSamples: [PositionSampleEntity]

    @State private var selectedNodeNum: Int64?
    @State private var weatherNodeNum: Int64?
    @State private var position: MapCameraPosition = .automatic
    @State private var mode: MapMode = .nodes
    @State private var waypointDraft: WaypointDraft?
    @Namespace private var mapScope

    enum MapMode: String, CaseIterable, Identifiable {
        case nodes = "Nodes"
        case weather = "Weather"
        case mesh = "Mesh"
        var id: String { rawValue }
    }

    struct WaypointDraft: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }

    private var placedNodes: [NodeEntity] {
        nodes.filter { $0.hasPosition && $0.num != radio.myNodeNum }
    }

    private var myNode: NodeEntity? {
        nodes.first { $0.num == radio.myNodeNum && $0.hasPosition }
    }

    private var weatherNodes: [NodeEntity] {
        nodes.filter { $0.hasPosition && $0.hasRecentEnvironment && !$0.weatherHidden }
    }

    private var activeWaypoints: [WaypointEntity] {
        waypoints.filter { $0.expires == nil || $0.expires! > Date() }
    }

    /// Trail for the node whose card is open — newest 100 samples, oldest first.
    private var selectedTrail: [PositionSampleEntity] {
        guard let num = selectedNodeNum else { return [] }
        return trailSamples
            .filter { $0.nodeNum == num }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(100)
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position, scope: mapScope) {
                    UserAnnotation()
                    switch mode {
                    case .nodes:
                        nodePins(displayNodes(from: placedNodes))
                        waypointContent
                    case .weather:
                        weatherContent
                    case .mesh:
                        nodePins(displayNodes(from: meshRelevantNodes))
                        myNodePin
                        meshEdges
                    }
                    trailContent
                }
                // Hybrid + realistic = satellite imagery on a true globe.
                .mapStyle(.hybrid(elevation: .realistic))
                .mapControls {
                    MapCompass()
                }
                // Long-press drops a shared waypoint (Nodes view).
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard mode == .nodes,
                                  case .second(true, let drag?) = value,
                                  let coordinate = proxy.convert(drag.location, from: .local)
                            else { return }
                            waypointDraft = WaypointDraft(coordinate: coordinate)
                        }
                )
            }
            .overlay(alignment: .top) {
                Picker("Map mode", selection: $mode) {
                    ForEach(MapMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                MapUserLocationButton(scope: mapScope)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
            }
            .mapScope(mapScope)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedNodeNum) { num in
                NodeCardView(nodeNum: num) {
                    selectedNodeNum = nil
                    appModel.openConversation(ConversationEntity.dmKey(num))
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $weatherNodeNum) { num in
                WeatherNodeSheet(nodeNum: num)
                    .presentationDetents([.height(300)])
            }
            .sheet(item: $waypointDraft) { draft in
                WaypointComposerView(coordinate: draft.coordinate)
                    .presentationDetents([.height(360)])
            }
            .overlay {
                if mode == .mesh && meshRelevantNodes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No known links yet")
                            .font(.headline)
                        Text("Direct neighbors appear as they're heard; more links arrive if nodes broadcast NeighborInfo (many meshes don't).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                }
                if mode == .weather && weatherNodes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cloud.sun")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No weather reports")
                            .font(.headline)
                        Text("Nodes with environment sensors appear here as their readings arrive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Layers

    /// Mesh view is connectivity only: nodes we're directly linked to, or that
    /// appear in NeighborInfo reports — not the whole node database.
    private var meshRelevantNodes: [NodeEntity] {
        let edgeNums = Set(radio.neighborEdges.flatMap { [$0.from, $0.to] })
        return placedNodes.filter { $0.hopsAway == 0 || edgeNums.contains($0.num) }
    }

    @MapContentBuilder
    private var myNodePin: some MapContent {
        if let mine = myNode {
            Annotation("You", coordinate: mine.coordinate) {
                MonogramAvatar(text: mine.monogram, isChannel: false, size: 34, imageData: mine.iconData)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 3))
                    .shadow(radius: 2)
            }
        }
    }

    @MapContentBuilder
    private func nodePins(_ nodes: [PlacedNode]) -> some MapContent {
        ForEach(nodes, id: \.node.num) { placed in
            let node = placed.node
            if node.precisionBits > 0 && node.precisionBits < 32 {
                MapCircle(center: node.coordinate, radius: node.precisionRadius)
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
            Annotation(node.displayName, coordinate: placed.coordinate) {
                MonogramAvatar(text: node.monogram, isChannel: false, size: 32,
                               dimmed: !node.isOnline, imageData: node.iconData)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(radius: 2)
                    .contentShape(Circle())
                    .onTapGesture {
                        selectedNodeNum = node.num
                    }
            }
        }
    }

    @MapContentBuilder
    private var waypointContent: some MapContent {
        ForEach(activeWaypoints) { waypoint in
            Annotation(waypoint.name, coordinate: CLLocationCoordinate2D(latitude: waypoint.latitude, longitude: waypoint.longitude)) {
                Text(waypoint.icon)
                    .font(.title3)
                    .padding(4)
                    .background(.thinMaterial, in: Circle())
            }
        }
    }

    @MapContentBuilder
    private var weatherContent: some MapContent {
        ForEach(weatherNodes, id: \.num) { node in
            Annotation(node.displayName, coordinate: node.coordinate) {
                WeatherPill(node: node)
                    .onTapGesture {
                        weatherNodeNum = node.num
                    }
            }
        }
    }

    /// Direct (0-hop) links from our node, plus edges other nodes report
    /// via NeighborInfo — line strength follows SNR.
    @MapContentBuilder
    private var meshEdges: some MapContent {
        if let mine = myNode {
            ForEach(placedNodes.filter { $0.hopsAway == 0 }, id: \.num) { neighbor in
                MapPolyline(coordinates: [mine.coordinate, neighbor.coordinate])
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 2.5)
            }
        }
        ForEach(resolvedNeighborEdges) { edge in
            MapPolyline(coordinates: [edge.a, edge.b])
                .stroke(.white.opacity(edge.strong ? 0.7 : 0.35), lineWidth: edge.strong ? 2 : 1)
        }
    }

    private struct ResolvedEdge: Identifiable {
        let id: String
        let a: CLLocationCoordinate2D
        let b: CLLocationCoordinate2D
        let strong: Bool
    }

    private var resolvedNeighborEdges: [ResolvedEdge] {
        let positioned = Dictionary(uniqueKeysWithValues: nodes.filter(\.hasPosition).map { ($0.num, $0.coordinate) })
        var seen = Set<String>()
        return radio.neighborEdges.compactMap { edge in
            guard let a = positioned[edge.from], let b = positioned[edge.to],
                  seen.insert(edge.id).inserted else { return nil }
            return ResolvedEdge(id: edge.id, a: a, b: b, strong: edge.snr > -10)
        }
    }

    /// Breadcrumb for the selected node: segments fade with age.
    @MapContentBuilder
    private var trailContent: some MapContent {
        let trail = selectedTrail
        if trail.count >= 2 {
            ForEach(1..<trail.count, id: \.self) { index in
                let age = Double(trail.count - index) / Double(trail.count)
                MapPolyline(coordinates: [
                    CLLocationCoordinate2D(latitude: trail[index - 1].latitude, longitude: trail[index - 1].longitude),
                    CLLocationCoordinate2D(latitude: trail[index].latitude, longitude: trail[index].longitude),
                ])
                .stroke(Color.orange.opacity(1.0 - age * 0.75), lineWidth: 3)
            }
        }
    }

    private struct PlacedNode {
        let node: NodeEntity
        let coordinate: CLLocationCoordinate2D
    }

    /// Nodes sharing a coordinate spread on a small deterministic ring so every
    /// pin stays tappable; precision circles stay on the true coordinate.
    private func displayNodes(from source: [NodeEntity]) -> [PlacedNode] {
        let groups = Dictionary(grouping: source) { node in
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

    var temperatureText: String {
        Measurement(value: Double(temperature), unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather))
    }
}

// MARK: - Weather

struct WeatherPill: View {
    let node: NodeEntity

    var body: some View {
        HStack(spacing: 5) {
            Text(node.temperatureText)
                .font(.footnote.weight(.semibold))
            if node.humidity >= 0 {
                Text("\(Int(node.humidity))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(radius: 1)
    }
}

struct WeatherNodeSheet: View {
    let nodeNum: Int64
    @Query private var nodes: [NodeEntity]
    @Environment(\.dismiss) private var dismiss

    init(nodeNum: Int64) {
        self.nodeNum = nodeNum
        let num = nodeNum
        _nodes = Query(filter: #Predicate<NodeEntity> { $0.num == num })
    }

    var body: some View {
        NavigationStack {
            if let node = nodes.first {
                List {
                    LabeledContent("Temperature", value: node.temperatureText)
                    if node.humidity >= 0 {
                        LabeledContent("Humidity", value: "\(Int(node.humidity))%")
                    }
                    if node.pressure > 0 {
                        LabeledContent("Pressure", value: String(format: "%.0f hPa", node.pressure))
                    }
                    if let at = node.envUpdatedAt {
                        LabeledContent("Updated", value: at.formatted(.relative(presentation: .named)))
                    }
                    Button("Hide From Weather Map", role: .destructive) {
                        node.weatherHidden = true
                        dismiss()
                    }
                }
                .navigationTitle(node.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

// MARK: - Waypoint composer

struct WaypointComposerView: View {
    let coordinate: CLLocationCoordinate2D

    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "📍"
    @State private var expireChoice = 0

    private static let emojiChoices = ["📍", "⛺️", "💧", "🍕", "🚻", "🅿️", "⚠️", "🏁", "🔧", "📡"]
    private static let expireChoices: [(String, TimeInterval?)] = [
        ("Never", nil), ("1 hour", 3600), ("8 hours", 28800), ("24 hours", 86400),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Water here)", text: $name)
                        .onChange(of: name) { _, newValue in
                            while newValue.utf8.count > 29 { name.removeLast(); return }
                        }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                        ForEach(Self.emojiChoices, id: \.self) { choice in
                            Button {
                                emoji = choice
                            } label: {
                                Text(choice)
                                    .font(.title3)
                                    .padding(6)
                                    .background(emoji == choice ? Color.accentColor.opacity(0.25) : .clear,
                                                in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Picker("Expires", selection: $expireChoice) {
                        ForEach(Array(Self.expireChoices.enumerated()), id: \.offset) { index, choice in
                            Text(choice.0).tag(index)
                        }
                    }
                } footer: {
                    Text("Broadcast on your primary channel — anyone on the mesh sees it on their map.")
                }
            }
            .navigationTitle("Drop Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let expire = Self.expireChoices[expireChoice].1.map { Date().addingTimeInterval($0) }
                        radio.sendWaypoint(name: name.isEmpty ? "Waypoint" : name, emoji: emoji,
                                           latitude: coordinate.latitude, longitude: coordinate.longitude,
                                           expire: expire, channel: 0)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
