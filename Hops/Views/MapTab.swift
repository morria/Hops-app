import SwiftUI
import SwiftData
import MapKit

struct MapTab: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel
    // Positioned nodes only — observing the whole node table re-rendered the
    // map on every packet that bumped any node's lastHeard.
    @Query(filter: #Predicate<NodeEntity> { $0.hasPosition == true })
    private var nodes: [NodeEntity]
    @Query private var waypoints: [WaypointEntity]

    /// MapKit chokes on thousands of annotations; show the most recently heard.
    private static let annotationCap = 300

    @State private var selectedNodeNum: Int64?
    @State private var weatherNodeNum: Int64?
    @State private var position: MapCameraPosition
    @AppStorage("mapModeRaw") private var modeRaw = MapMode.nodes.rawValue

    // Map filters (persisted): -1 hops = any; 0 hours = any age.
    @AppStorage("mapFilterMaxHops") private var filterMaxHops = -1
    @AppStorage("mapFilterMaxAgeHours") private var filterMaxAgeHours = 0

    private var filtersActive: Bool { filterMaxHops >= 0 || filterMaxAgeHours > 0 }

    /// Node passes the active map filters. Hop filtering excludes nodes with
    /// unknown path length — "within N hops" is a claim we can't make for them.
    private func passesFilters(_ node: NodeEntity) -> Bool {
        if filterMaxHops >= 0 {
            guard node.hopsAway >= 0, node.hopsAway <= filterMaxHops else { return false }
        }
        if filterMaxAgeHours > 0 {
            guard let heard = node.lastHeard,
                  heard > Date().addingTimeInterval(-Double(filterMaxAgeHours) * 3600)
            else { return false }
        }
        return true
    }
    @State private var waypointDraft: WaypointDraft?
    @State private var visibleRegion: MKCoordinateRegion?
    @Namespace private var mapScope

    /// Persisted view mode — reopening the map lands where you left it.
    private var mode: MapMode {
        get { MapMode(rawValue: modeRaw) ?? .nodes }
    }
    private var modeBinding: Binding<MapMode> {
        Binding(get: { MapMode(rawValue: modeRaw) ?? .nodes },
                set: { modeRaw = $0.rawValue })
    }

    init() {
        // Restore the last camera; fall back to auto-framing the mesh.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "mapCenterLat") != nil {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: defaults.double(forKey: "mapCenterLat"),
                                               longitude: defaults.double(forKey: "mapCenterLon")),
                span: MKCoordinateSpan(latitudeDelta: defaults.double(forKey: "mapSpanLat"),
                                       longitudeDelta: defaults.double(forKey: "mapSpanLon")))
            _position = State(initialValue: .region(region))
        } else {
            _position = State(initialValue: .automatic)
        }
    }

    private func persistCamera(_ region: MKCoordinateRegion) {
        let defaults = UserDefaults.standard
        defaults.set(region.center.latitude, forKey: "mapCenterLat")
        defaults.set(region.center.longitude, forKey: "mapCenterLon")
        defaults.set(region.span.latitudeDelta, forKey: "mapSpanLat")
        defaults.set(region.span.longitudeDelta, forKey: "mapSpanLon")
    }

    /// Pan so a tapped coordinate sits in the upper half, clear of the sheet.
    private func focus(on coordinate: CLLocationCoordinate2D) {
        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude - span.latitudeDelta * 0.22,
                                            longitude: coordinate.longitude)
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    enum BaseStyle: String, CaseIterable, Identifiable {
        case explore = "Explore"
        case hybrid = "Hybrid"
        case satellite = "Satellite"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .explore: return "map"
            case .hybrid: return "map.fill"
            case .satellite: return "globe.americas.fill"
            }
        }

        var style: MapStyle {
            switch self {
            case .explore: return .standard(elevation: .realistic)
            case .hybrid: return .hybrid(elevation: .realistic)
            case .satellite: return .imagery(elevation: .realistic)
            }
        }
    }

    @AppStorage("mapBaseStyleRaw") private var baseStyleRaw = BaseStyle.hybrid.rawValue
    private var baseStyle: BaseStyle { BaseStyle(rawValue: baseStyleRaw) ?? .hybrid }
    private var baseStyleBinding: Binding<BaseStyle> {
        Binding(get: { BaseStyle(rawValue: baseStyleRaw) ?? .hybrid },
                set: { baseStyleRaw = $0.rawValue })
    }

    enum MapMode: String, CaseIterable, Identifiable {
        case nodes = "Nodes"
        case weather = "Weather"
        case coverage = "Coverage"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .nodes: return "dot.radiowaves.left.and.right"
            case .weather: return "cloud.sun"
            case .coverage: return "chart.dots.scatter"
            }
        }
    }

    struct WaypointDraft: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }

    private var placedNodes: [NodeEntity] {
        let others = nodes.filter { $0.num != radio.myNodeNum && passesFilters($0) }
        guard others.count > Self.annotationCap else { return others }
        return Array(others.sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
            .prefix(Self.annotationCap))
    }

    private var myNode: NodeEntity? {
        nodes.first { $0.num == radio.myNodeNum && $0.hasPosition }
    }

    private var weatherNodes: [NodeEntity] {
        nodes.filter { $0.hasPosition && $0.hasRecentEnvironment && !$0.weatherHidden && passesFilters($0) }
    }

    private var activeWaypoints: [WaypointEntity] {
        waypoints.filter { $0.expires == nil || $0.expires! > Date() }
    }

    /// Trail for the node whose card is open — fetched on selection, not observed.
    @State private var selectedTrail: [CLLocationCoordinate2D] = []

    private func loadTrail(for num: Int64?) {
        guard let num else { selectedTrail = []; return }
        var descriptor = FetchDescriptor<PositionSampleEntity>(
            predicate: #Predicate { $0.nodeNum == num })
        descriptor.sortBy = [SortDescriptor(\.timestamp)]
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        selectedTrail = samples.suffix(100).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
    @Environment(\.modelContext) private var modelContext

    /// Heavy per-render work (sort, de-overlap grouping) runs on a 5 s cadence
    /// into snapshots instead of on every position-driven invalidation.
    @State private var placedSnapshot: [PlacedNode] = []
    @State private var weatherSnapshot: [NodeEntity] = []

    struct CoveragePoint: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let snr: Float
    }
    @State private var coverageSnapshot: [CoveragePoint] = []

    /// Citywide reach: each recently-heard positioned node, with its hop
    /// distance from us — being near that node ≈ that many hops to reach you.
    struct ReachPoint: Identifiable {
        let id: Int64
        let coordinate: CLLocationCoordinate2D
        let hops: Int
    }
    @State private var reachSnapshot: [ReachPoint] = []

    /// Interpolated contact-prediction surface: grid cells colored by expected
    /// hop distance (IDW over nodes + measured samples), clear where there's
    /// no evidence within ~1.5 km. Four discrete color bins (matching the
    /// node reach palette) instead of a continuous hue — contiguous regions
    /// of one color read at a glance; olive in-betweens vanish into satellite
    /// terrain.
    struct HeatCell: Identifiable {
        let id: Int
        let corners: [CLLocationCoordinate2D]
        let color: Color
        let opacity: Double
    }
    @State private var heatGrid: [HeatCell] = []
    @State private var lastHeatAt = Date.distantPast

    private func recomputeHeatGrid() {
        guard mode == .coverage, let region = visibleRegion else { return }
        lastHeatAt = Date()
        // Observed-topology refinement: BFS over NeighborInfo links plus our
        // own direct links beats the firmware's flood-based hop counter where
        // we have real edges.
        var adjacency: [Int64: Set<Int64>] = [:]
        for edge in radio.neighborEdges {
            adjacency[edge.from, default: []].insert(edge.to)
            adjacency[edge.to, default: []].insert(edge.from)
        }
        let myNum = radio.myNodeNum
        for point in reachSnapshot where point.hops == 0 {
            adjacency[myNum, default: []].insert(point.id)
            adjacency[point.id, default: []].insert(myNum)
        }
        var graphHops: [Int64: Int] = [myNum: 0]
        var frontier: [Int64] = [myNum]
        while !frontier.isEmpty {
            var next: [Int64] = []
            for node in frontier {
                for neighbor in adjacency[node] ?? [] where graphHops[neighbor] == nil {
                    graphHops[neighbor] = graphHops[node]! + 1
                    next.append(neighbor)
                }
            }
            frontier = next
        }
        func refinedHops(_ id: Int64, firmware: Int) -> Double {
            let fw = firmware >= 0 ? Double(firmware) : 3.0
            if let g = graphHops[id] { return min(fw, Double(g)) }
            return fw
        }

        // Evidence points: (lat, lon, effectiveHops)
        var points: [(Double, Double, Double)] = reachSnapshot.map {
            ($0.coordinate.latitude, $0.coordinate.longitude, refinedHops($0.id, firmware: $0.hops))
        }

        // Corridor evidence: an observed RF link means propagation works along
        // that segment — color the space between linked nodes, not just endpoints.
        let positionByNum = Dictionary(uniqueKeysWithValues: reachSnapshot.map { ($0.id, ($0.coordinate, $0.hops)) })
        for edge in radio.neighborEdges {
            guard let (a, aHops) = positionByNum[edge.from],
                  let (b, bHops) = positionByNum[edge.to] else { continue }
            let best = min(refinedHops(edge.from, firmware: aHops), refinedHops(edge.to, firmware: bHops))
            for t in [0.3, 0.5, 0.7] {
                points.append((a.latitude + (b.latitude - a.latitude) * t,
                               a.longitude + (b.longitude - a.longitude) * t,
                               best + 0.75))
            }
        }
        points += coverageSnapshot.map {
            // A strong measured sample is as good as being next to a direct node.
            let effective: Double = $0.snr >= -5 ? 0 : ($0.snr >= -12 ? 1.5 : 3.5)
            return ($0.coordinate.latitude, $0.coordinate.longitude, effective)
        }
        guard !points.isEmpty else { heatGrid = []; return }

        let cols = 18
        let rows = min(32, max(12, Int(Double(cols) * region.span.latitudeDelta / region.span.longitudeDelta)))
        let influence = 0.015   // ~1.5 km in degrees latitude
        let cellLat = region.span.latitudeDelta / Double(rows)
        let cellLon = region.span.longitudeDelta / Double(cols)
        // World-anchored origin (snapped to cell multiples): panning slides
        // over a fixed grid instead of reflowing every cell.
        let originLat = floor((region.center.latitude - region.span.latitudeDelta / 2) / cellLat) * cellLat
        let originLon = floor((region.center.longitude - region.span.longitudeDelta / 2) / cellLon) * cellLon
        var cells: [HeatCell] = []
        cells.reserveCapacity((rows + 1) * (cols + 1))
        var cellId = 0
        for row in 0...rows {
            for col in 0...cols {
                let lat = originLat + (Double(row) + 0.5) * cellLat
                let lon = originLon + (Double(col) + 0.5) * cellLon
                var weightSum = 0.0
                var valueSum = 0.0
                for (plat, plon, hops) in points {
                    let dLat = plat - lat
                    let dLon = (plon - lon) * 0.766   // cos(40°) longitude squeeze
                    let d2 = dLat * dLat + dLon * dLon
                    guard d2 < influence * influence else { continue }
                    let w = 1.0 / max(d2, 1e-8)
                    weightSum += w
                    valueSum += w * hops
                }
                guard weightSum > 0 else { cellId += 1; continue }
                let expectedHops = valueSum / weightSum
                // Same four bins as the node reach palette — one legend.
                let color: Color = expectedHops < 0.75 ? .green
                    : expectedHops < 2.5 ? .mint
                    : expectedHops < 4.5 ? .yellow
                    : .orange
                // Two opacity levels, not a continuum — neighboring cells at
                // slightly different confidence otherwise checkerboard.
                let confidence = min(1.0, weightSum / 20_000)
                cells.append(HeatCell(
                    id: cellId,
                    corners: [
                        CLLocationCoordinate2D(latitude: originLat + Double(row) * cellLat, longitude: originLon + Double(col) * cellLon),
                        CLLocationCoordinate2D(latitude: originLat + Double(row) * cellLat, longitude: originLon + Double(col + 1) * cellLon),
                        CLLocationCoordinate2D(latitude: originLat + Double(row + 1) * cellLat, longitude: originLon + Double(col + 1) * cellLon),
                        CLLocationCoordinate2D(latitude: originLat + Double(row + 1) * cellLat, longitude: originLon + Double(col) * cellLon),
                    ],
                    color: color,
                    opacity: confidence >= 0.3 ? 0.26 : 0.15))
                cellId += 1
            }
        }
        heatGrid = cells
    }

    @State private var lastSnapshotAt = Date.distantPast

    private func refreshSnapshots() {
        lastSnapshotAt = Date()
        placedSnapshot = displayNodes(from: placedNodes)
        weatherSnapshot = weatherNodes
        defer { if mode == .coverage { recomputeHeatGrid() } }
        if mode == .coverage {
            let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
            reachSnapshot = nodes
                .filter { $0.num != radio.myNodeNum && ($0.lastHeard ?? .distantPast) > dayAgo }
                .map { ReachPoint(id: $0.num, coordinate: $0.coordinate, hops: $0.hopsAway) }
            var descriptor = FetchDescriptor<CoverageSampleEntity>()
            descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
            descriptor.fetchLimit = 600
            let samples = (try? modelContext.fetch(descriptor)) ?? []
            coverageSnapshot = samples.enumerated().map { index, sample in
                CoveragePoint(id: index,
                              coordinate: CLLocationCoordinate2D(latitude: sample.latitude,
                                                                 longitude: sample.longitude),
                              snr: sample.snr)
            }
        }
    }

    private func coverageColor(_ snr: Float) -> Color {
        if snr >= -5 { return .green }
        if snr >= -12 { return .yellow }
        return .red
    }

    private func legendKey(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func reachColor(_ hops: Int) -> Color {
        switch hops {
        case 0: return .green        // direct copy from here
        case 1, 2: return .mint
        case 3, 4: return .yellow
        case 5...: return .orange
        default: return .gray        // heard, path length unknown
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position, scope: mapScope) {
                    UserAnnotation()
                    switch mode {
                    case .nodes:
                        nodePins(placedSnapshot)
                        waypointContent
                    case .weather:
                        weatherContent
                    case .coverage:
                        coverageContent
                    }
                    trailContent
                }
                .mapStyle(baseStyle.style)   // user-chosen base, realistic globe
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
            // Apple Maps-style layers control: a circle that opens the view chooser,
            // stacked above locate-me.
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    if mode != .coverage {
                        Menu {
                            Picker("Hops away", selection: $filterMaxHops) {
                                Text("Any distance").tag(-1)
                                Text("Direct only").tag(0)
                                Text("Within 1 hop").tag(1)
                                Text("Within 2 hops").tag(2)
                                Text("Within 4 hops").tag(4)
                            }
                            Divider()
                            Picker("Heard within", selection: $filterMaxAgeHours) {
                                Text("Any time").tag(0)
                                Text("Last hour").tag(1)
                                Text("Last 6 hours").tag(6)
                                Text("Last 24 hours").tag(24)
                                Text("Last 7 days").tag(168)
                            }
                            if filtersActive {
                                Divider()
                                Button("Clear Filters") {
                                    filterMaxHops = -1
                                    filterMaxAgeHours = 0
                                }
                            }
                        } label: {
                            Image(systemName: filtersActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(filtersActive ? Color.accentColor : .primary)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        }
                    }
                    Menu {
                        Picker("Map view", selection: modeBinding) {
                            ForEach(MapMode.allCases) { choice in
                                Label(choice.rawValue, systemImage: choice.icon).tag(choice)
                            }
                        }
                        Divider()
                        Picker("Map style", selection: baseStyleBinding) {
                            ForEach(BaseStyle.allCases) { choice in
                                Label(choice.rawValue, systemImage: choice.icon).tag(choice)
                            }
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d.top.filled")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    MapUserLocationButton(scope: mapScope)
                        .buttonBorderShape(.circle)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            // The coverage layer needs a key — four colors, two dot palettes.
            .overlay(alignment: .topLeading) {
                if mode == .coverage {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            legendKey(.green, "Direct")
                            legendKey(.mint, "1–2 hops")
                            legendKey(.yellow, "3–4")
                            legendKey(.orange, "5+")
                        }
                        Text("Predicted hops from there to you · dots are your measured signal")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.leading, 16)
                    .padding(.top, 8)
                }
            }
            .mapScope(mapScope)
            .onChange(of: filterMaxHops) { _, _ in refreshSnapshots() }
            .onChange(of: filterMaxAgeHours) { _, _ in refreshSnapshots() }
            .onMapCameraChange { context in
                visibleRegion = context.region
                persistCamera(context.region)
                // Re-interpolate for the new viewport (debounced).
                if mode == .coverage, Date().timeIntervalSince(lastHeatAt) > 1.0 {
                    recomputeHeatGrid()
                }
            }
            .onAppear {
                refreshSnapshots()
                // The map can LAUNCH in Coverage (persisted layer) — the
                // switch-based prompt never fires in that case.
                if mode == .coverage {
                    Task { _ = await LocationProvider.shared.current() }
                }
            }
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                // Only while the Map tab is actually visible; slower in saver.
                guard appModel.selectedTab == 1,
                      Date().timeIntervalSince(lastSnapshotAt) >= (PowerMode.saver ? 30 : 5)
                else { return }
                refreshSnapshots()
            }
            .onChange(of: selectedNodeNum) { _, num in
                loadTrail(for: num)
            }
            .onChange(of: modeRaw) { _, raw in
                refreshSnapshots()   // switching layers shouldn't wait for the timer
                if raw == MapMode.coverage.rawValue {
                    // Explicit intent: ask for location if never asked, and warm
                    // a fix so passive sampling has something to pair with SNR.
                    Task { _ = await LocationProvider.shared.current() }
                }
            }
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
                if mode == .coverage && coverageSnapshot.isEmpty && reachSnapshot.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.dots.scatter")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No coverage data yet")
                            .font(.headline)
                        if PowerMode.saver {
                            Text("Coverage sampling is paused by Battery Saver (or iOS Low Power Mode). Turn it off in Settings to resume.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else if !LocationProvider.shared.isAuthorized {
                            Text("Hops needs your location to pair signal readings with where you were.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Enable Location Access") {
                                if LocationProvider.shared.authorizationStatus == .notDetermined {
                                    Task { _ = await LocationProvider.shared.current() }
                                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        } else {
                            Text("Carry your radio around — whenever it hears the mesh (even with your phone in your pocket), Hops records signal quality and paints it here. Green is strong, red is weak.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
                        focus(on: placed.coordinate)
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

    /// Reachability across the city: blobs around every recently-heard node,
    /// colored by hop distance from you (green = hears you directly, warmer =
    /// farther through the mesh). Your own measured samples draw on top as
    /// ground-truth dots.
    @MapContentBuilder
    private var coverageContent: some MapContent {
        ForEach(heatGrid) { cell in
            MapPolygon(coordinates: cell.corners)
                .foregroundStyle(cell.color.opacity(cell.opacity))
        }
        ForEach(coverageSnapshot) { point in
            Annotation("", coordinate: point.coordinate) {
                Circle()
                    .fill(coverageColor(point.snr).opacity(0.8))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
            }
        }
        UserAnnotation()
    }

    @MapContentBuilder
    private var weatherContent: some MapContent {
        ForEach(weatherSnapshot, id: \.num) { node in
            // No station label on the map — the sheet has the name.
            Annotation("", coordinate: node.coordinate) {
                WeatherPill(node: node)
                    .onTapGesture {
                        focus(on: node.coordinate)
                        weatherNodeNum = node.num
                    }
            }
        }
    }

    /// Breadcrumb for the selected node: segments fade with age.
    @MapContentBuilder
    private var trailContent: some MapContent {
        let trail = selectedTrail
        if trail.count >= 2 {
            ForEach(1..<trail.count, id: \.self) { index in
                let age = Double(trail.count - index) / Double(trail.count)
                MapPolyline(coordinates: [trail[index - 1], trail[index]])
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

}

/// Whole-degree temperature text in the user's chosen unit.
enum TempFormat {
    static func text(celsius: Float, fahrenheit: Bool) -> String {
        let value = fahrenheit ? Double(celsius) * 9 / 5 + 32 : Double(celsius)
        return "\(Int(value.rounded()))°\(fahrenheit ? "F" : "C")"
    }
}

// MARK: - Weather

struct WeatherPill: View {
    let node: NodeEntity
    @AppStorage("useFahrenheit") private var useFahrenheit = Locale.current.measurementSystem != .metric

    var body: some View {
        HStack(spacing: 5) {
            Text(TempFormat.text(celsius: node.temperature, fahrenheit: useFahrenheit))
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
    @AppStorage("useFahrenheit") private var useFahrenheit = Locale.current.measurementSystem != .metric

    init(nodeNum: Int64) {
        self.nodeNum = nodeNum
        let num = nodeNum
        _nodes = Query(filter: #Predicate<NodeEntity> { $0.num == num })
    }

    var body: some View {
        NavigationStack {
            if let node = nodes.first {
                List {
                    LabeledContent("Temperature",
                                   value: TempFormat.text(celsius: node.temperature, fahrenheit: useFahrenheit))
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
