import Foundation
import Combine
import CoreBluetooth
import SwiftData
import OSLog
import MeshtasticProtobufs

@MainActor
final class RadioManager: ObservableObject {

    static let shared = RadioManager(transport: BLECentral())

    enum State: Equatable {
        case bluetoothOff
        case noRadio                 // never paired
        case offline                 // paired, radio not reachable (pending connect armed)
        case connecting
        case syncing                 // link up, config/queue drain in flight
        case connected
        case bondLost
    }

    @Published private(set) var state: State = .noRadio
    /// When the transmit radio's session began — consumers that expire
    /// things by "time without hearing X" must not count time we weren't
    /// listening at all.
    private(set) var connectedAt: Date?
    @Published private(set) var discovered: [BLECentral.Discovered] = []
    @Published private(set) var lastSyncedAt: Date?

    // MARK: - Fleet (docs/MULTI_RADIO.md)

    /// One radio the phone currently holds a link to, for the UI.
    struct AttachedRadio: Identifiable, Equatable {
        let id: UUID
        let nodeNum: Int64
        let phase: RadioLink.Phase
        let firmware: String
        let isTransmit: Bool
        let drift: [String]
        let roleRaw: Int?     // device role as the radio reported it
    }
    @Published private(set) var attached: [AttachedRadio] = []
    /// Every radio the owner has added, in priority order (from the store).
    @Published private(set) var fleet: [MessageStore.RadioSnapshot] = []
    @Published var needsMeshSetup = false     // factory-fresh radio: region unset

    // Mesh-traffic diagnostics (since launch): distinguishes "radio hears nothing"
    // (config/frequency problem) from "app mishandles what arrives" (our bug).
    // Per-packet counters live on TrafficMonitor (TODO 188) so a heard
    // packet doesn't republish RadioManager to every view observing it.
    var meshPacketsHeard: Int { TrafficMonitor.shared.meshPacketsHeard }
    var textMessagesHeard: Int { TrafficMonitor.shared.textMessagesHeard }
    var lastMeshPacketAt: Date? { TrafficMonitor.shared.lastMeshPacketAt }

    // Store & Forward: the last router heard heartbeating, for history recovery.
    private var sfRouterNum: Int64 {
        get { Int64(defaults.integer(forKey: "sfRouterNum")) }
        set { defaults.set(newValue, forKey: "sfRouterNum") }
    }
    private var sfRouterHeardAt: Date? {
        get { defaults.object(forKey: "sfRouterHeardAt") as? Date }
        set { defaults.set(newValue, forKey: "sfRouterHeardAt") }
    }

    /// Mesh-topology edges learned from NeighborInfo broadcasts (session-only):
    /// (reporter, neighbor, snr).
    @Published private(set) var neighborEdges: [NeighborEdge] = []
    struct NeighborEdge: Identifiable, Equatable {
        let from: Int64
        let to: Int64
        let snr: Float
        var id: String { "\(min(from, to))-\(max(from, to))" }
    }

    // Device configs mirrored from the connect-time dump; nil until received.
    @Published var bluetoothConfig: Config.BluetoothConfig?
    @Published var deviceConfig: Config.DeviceConfig?
    @Published var displayConfig: Config.DisplayConfig?
    @Published var positionConfig: Config.PositionConfig?
    @Published var telemetryConfig: ModuleConfig.TelemetryConfig?

    struct TrafficEntry: Identifiable {
        let id: Int
        let date: Date
        let fromNum: Int64
        let portName: String
        let summary: String
        let snr: Float          // 0 = not reported
        let hopsAway: Int       // -1 = unknown
    }
    // Coverage survey accumulator: best SNR heard since the last sample.
    private var coverageSnrMax: Float = -999
    private var coveragePackets = 0
    private var coverageSampledAt = Date.distantPast
    /// Our radio's own GPS fix, delivered in the same packet flushes.
    private var myLastPosition: (lat: Double, lon: Double, at: Date)?

    /// Samples background and foreground alike — position comes free from the
    /// radio's own GPS or the phone's cached fix; GPS is only actively used
    /// when the app is already on screen.
    private func accumulateCoverage(snr: Float) {
        guard snr != 0, !PowerMode.saver else { return }
        coverageSnrMax = max(coverageSnrMax, snr)
        coveragePackets += 1
        guard Date().timeIntervalSince(coverageSampledAt) > 30, let store else { return }

        var latitude: Double?
        var longitude: Double?
        if let mine = myLastPosition, Date().timeIntervalSince(mine.at) < 600 {
            latitude = mine.lat            // radio GPS: best source, zero cost
            longitude = mine.lon
        } else if LocationProvider.shared.isAuthorized,
                  let cached = LocationProvider.shared.cachedLocation,
                  Date().timeIntervalSince(cached.timestamp) < 300 {
            latitude = cached.coordinate.latitude   // passive phone fix
            longitude = cached.coordinate.longitude
        }

        let snapshotSnr = coverageSnrMax
        let snapshotCount = coveragePackets

        if let latitude, let longitude {
            coverageSampledAt = Date()
            coverageSnrMax = -999
            coveragePackets = 0
            Task {
                await store.addCoverageSample(latitude: latitude, longitude: longitude,
                                              snr: snapshotSnr, packets: snapshotCount)
            }
        } else if UIStateObserver.shared.isActive, LocationProvider.shared.isAuthorized {
            // On screen: allowed to spin up a fresh fix.
            coverageSampledAt = Date()
            coverageSnrMax = -999
            coveragePackets = 0
            Task {
                guard let location = await LocationProvider.shared.current() else { return }
                await store.addCoverageSample(latitude: location.coordinate.latitude,
                                              longitude: location.coordinate.longitude,
                                              snr: snapshotSnr, packets: snapshotCount)
            }
        }
    }

    /// Rolling log of decoded mesh traffic, newest first (capped).
    var trafficLog: [TrafficEntry] { TrafficMonitor.shared.entries }

    private func logTraffic(from: Int64, port: String, summary: String,
                            snr: Float = 0, hopsAway: Int = -1) {
        TrafficMonitor.shared.append(from: from, port: port, summary: summary, snr: snr, hopsAway: hopsAway)
    }

    /// App-level breadcrumbs (deep links, notification taps) in the same
    /// log as mesh traffic, so a "tap did nothing" report comes with a trail.
    func noteAppEvent(_ text: String) {
        logTraffic(from: myNodeNum, port: "app", summary: text)
    }

    // Connected radio facts (mirrored to UserDefaults for cold launches).
    @Published private(set) var myNodeNum: Int64
    @Published private(set) var firmwareVersion: String
    @Published private(set) var loRa: LoRaSnapshot

    struct LoRaSnapshot: Equatable {
        var received = false
        var regionRaw: Int = 0
        var presetRaw: Int = 0
        var frequencySlot: Int = 0
        var hopLimit: Int = 3

        var regionName: String {
            let region = Config.LoRaConfig.RegionCode(rawValue: regionRaw) ?? .unset
            return region == .unset ? "Not set" : String(describing: region).uppercased()
        }
        var presetName: String {
            guard received else { return "—" }
            let preset = Config.LoRaConfig.ModemPreset(rawValue: presetRaw) ?? .longFast
            switch preset {
            case .longFast: return "LongFast"
            case .longSlow: return "LongSlow"
            case .longModerate: return "LongModerate"
            case .mediumFast: return "MediumFast"
            case .mediumSlow: return "MediumSlow"
            case .shortFast: return "ShortFast"
            case .shortSlow: return "ShortSlow"
            case .shortTurbo: return "ShortTurbo"
            default: return String(describing: preset)
            }
        }
    }

    private let log = Logger(subsystem: "com.w2asm.hops", category: "radio")
    private let central: any RadioTransport
    /// Every peripheral we hold, are connecting to, or keep a pending
    /// connect armed for, with its per-session state.
    private var links: [UUID: RadioLink] = [:]
    private var store: MessageStore?
    private var bluetoothOn = false
    private var pairingInProgress = false

    /// The set_owner in flight: its packet id and the names to restore if the
    /// radio NAKs it (the local mirror is applied optimistically).
    private struct PendingOwner {
        let packetId: UInt32
        let previousLong: String
        let previousShort: String
    }
    private var pendingOwner: PendingOwner?
    private var pendingAdminAcks: [UInt32: CheckedContinuation<Bool, Never>] = [:]

    /// The radio a send goes through: the highest-priority attached radio
    /// (fleet order), or whichever is connected if the fleet order doesn't
    /// know it yet.
    var transmitLink: RadioLink? {
        let connected = links.values.filter { $0.phase == .connected && $0.nodeNum > 0 }
        guard !connected.isEmpty else { return nil }
        return connected.min { a, b in
            let pa = fleetPriority(a.nodeNum), pb = fleetPriority(b.nodeNum)
            if pa != pb { return pa < pb }
            return (a.connectedAt ?? .distantPast) < (b.connectedAt ?? .distantPast)
        }
    }
    private func fleetPriority(_ nodeNum: Int64) -> Int {
        fleet.firstIndex { $0.nodeNum == nodeNum } ?? Int.max
    }

    /// Is this node number one of the owner's radios?
    func isMine(_ num: Int64) -> Bool {
        guard num > 0 else { return false }
        return fleetPeripherals[num] != nil || num == myNodeNum || links.values.contains { $0.nodeNum == num }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let peripheralId = "pairedPeripheralId"   // pre-fleet single radio
        static let fleetPeripherals = "fleetPeripherals" // nodeNum → peripheral id, this device
        static let myNodeNum = "myNodeNum"
        static let lastSynced = "lastSyncedAt"
        static let firmware = "firmwareVersion"
        static let region = "loraRegion"
        static let preset = "loraPreset"
        static let slot = "loraSlot"
        static let hopLimit = "loraHopLimit"
        static let loraReceived = "loraReceived"
    }

    /// Bluetooth identifiers are per iOS device, so this map is local: which
    /// peripheral is which fleet radio on this phone.
    private var fleetPeripherals: [Int64: UUID] = [:] {
        didSet {
            var raw: [String: String] = [:]
            for (num, id) in fleetPeripherals { raw[String(num)] = id.uuidString }
            defaults.set(raw, forKey: Keys.fleetPeripherals)
        }
    }
    /// Just paired on this device, MyInfo not seen yet.
    private var pendingPeripherals: Set<UUID> = []
    private var wantedPeripheralIds: Set<UUID> { Set(fleetPeripherals.values).union(pendingPeripherals) }

    /// Pre-fleet callers ask "is any radio paired?".
    var pairedPeripheralId: UUID? {
        fleetPeripherals.values.first ?? pendingPeripherals.first
    }

    /// The key of the conversation currently on screen; its messages don't notify.
    var activeConversationKey: String?

    /// `shared` uses Core Bluetooth; tests inject a scripted transport and
    /// their own defaults suite.
    init(transport: any RadioTransport, defaults: UserDefaults = .standard) {
        self.central = transport
        self.defaults = defaults
        myNodeNum = Int64(defaults.integer(forKey: Keys.myNodeNum))
        firmwareVersion = defaults.string(forKey: Keys.firmware) ?? ""
        lastSyncedAt = defaults.object(forKey: Keys.lastSynced) as? Date
        loRa = LoRaSnapshot(
            received: defaults.bool(forKey: Keys.loraReceived),
            regionRaw: defaults.integer(forKey: Keys.region),
            presetRaw: defaults.integer(forKey: Keys.preset),
            frequencySlot: defaults.integer(forKey: Keys.slot),
            hopLimit: max(1, defaults.integer(forKey: Keys.hopLimit))
        )
        // Fleet peripherals on this device; migrate the single pre-fleet
        // radio into a one-member fleet.
        var map: [Int64: UUID] = [:]
        for (k, v) in defaults.dictionary(forKey: Keys.fleetPeripherals) as? [String: String] ?? [:] {
            if let num = Int64(k), let id = UUID(uuidString: v) { map[num] = id }
        }
        if map.isEmpty, let old = defaults.string(forKey: Keys.peripheralId).flatMap(UUID.init(uuidString:)) {
            if myNodeNum > 0 { map[myNodeNum] = old } else { pendingPeripherals.insert(old) }
        }
        fleetPeripherals = map
        for id in wantedPeripheralIds { links[id] = RadioLink(id: id) }
        state = wantedPeripheralIds.isEmpty ? .noRadio : .offline
        central.onEvent = { [weak self] event in self?.handle(event) }
        // Bluetooth comes up at launch only for an already-paired radio (the
        // central must exist early for iOS state restoration). A fresh
        // install first sees the Bluetooth prompt when it starts pairing.
        if !wantedPeripheralIds.isEmpty { central.activate() }
    }

    func configure(container: ModelContainer) {
        let store = MessageStore(modelContainer: container)
        self.store = store
        let localNums = Set(fleetPeripherals.keys).union(myNodeNum > 0 ? [myNodeNum] : [])
        Task {
            // Before any maintenance pass: the store must know which records
            // are us, so a renumber merge or a stale prune can't delete them.
            await store.setLocalNodeNums(localNums)
            await store.setEventSink { text in
                Task { @MainActor in RadioManager.shared.noteAppEvent(text) }
            }
            // Migration: the pre-fleet radio becomes fleet member #1.
            if myNodeNum > 0, await store.radios().isEmpty {
                await store.upsertRadio(nodeNum: myNodeNum, firmware: firmwareVersion, publicKey: nil, battery: nil)
            }
            await reloadFleet()
            await store.repairConversations()
            await store.pruneTrails()
            await store.pruneCoverage()
            await store.pruneStaleNodes(olderThanDays: UserDefaults.standard.object(forKey: "nodeMaxAgeDays") as? Int ?? 90)
        }
    }

    /// Re-read the fleet (priority order) from the store and re-derive the
    /// transmit radio.
    func reloadFleet() async {
        guard let store else { return }
        fleet = await store.radios()
        let nums = Set(fleet.map(\.nodeNum)).union(links.values.compactMap { $0.nodeNum > 0 ? $0.nodeNum : nil })
        await store.setLocalNodeNums(nums)
        refreshFacade()
    }

    // MARK: - Fleet editing

    func renameRadio(_ nodeNum: Int64, nickname: String) {
        Task { await store?.updateRadio(nodeNum: nodeNum, nickname: nickname); await reloadFleet() }
    }

    func setRadioLocation(_ nodeNum: Int64, tag: String) {
        Task { await store?.updateRadio(nodeNum: nodeNum, locationTag: tag); await reloadFleet() }
    }

    /// New priority order; the transmit radio follows it immediately.
    func reorderFleet(_ nodeNums: [Int64]) {
        Task { await store?.reorderRadios(nodeNums); await reloadFleet() }
    }

    /// Called when the retention setting changes.
    func applyNodeRetention() {
        guard let store else { return }
        let days = UserDefaults.standard.object(forKey: "nodeMaxAgeDays") as? Int ?? 90
        Task { await store.pruneStaleNodes(olderThanDays: days) }
    }

    // MARK: - Pairing (first radio, or adding one to the fleet)

    @Published private(set) var pairingPeripheralId: UUID?
    /// Node number of the radio just paired, once its MyInfo lands — the
    /// add-radio flow watches this to finish.
    @Published private(set) var pairedNodeNum: Int64 = 0

    /// Phase of the radio being paired right now (add-radio flow).
    var pairingPhase: RadioLink.Phase? { pairingPeripheralId.flatMap { links[$0]?.phase } }

    func beginPairingScan() {
        discovered = []
        pairingInProgress = true
        pairingPeripheralId = nil
        pairedNodeNum = 0
        central.activate()   // first Bluetooth prompt on a fresh install lands here
        central.startScan()  // no-op until powered on; the state event re-issues it
    }

    func endPairingScan() {
        pairingInProgress = false
        central.stopScan()
    }

    func pair(with id: UUID) {
        pairingInProgress = false
        pendingPeripherals.insert(id)
        pairingPeripheralId = id
        pairedNodeNum = 0
        let link = RadioLink(id: id)
        link.phase = .connecting
        links[id] = link
        central.connectDiscovered(id: id)
        armWatchdog(link)
        refreshFacade()
    }

    /// Drop one radio from the fleet on every device (the row syncs) and
    /// from this phone's Bluetooth map.
    func forget(radio nodeNum: Int64) {
        if let id = fleetPeripherals.removeValue(forKey: nodeNum) {
            links[id]?.watchdog?.cancel()
            links[id] = nil
            central.forget(id)
        }
        Task {
            await store?.deleteRadio(nodeNum: nodeNum)
            await reloadFleet()
        }
        if fleetPeripherals.isEmpty { resetSingleRadioDefaults() }
        refreshFacade()
    }

    /// Forget every radio (the pre-fleet "Forget This Radio").
    func forgetRadio() {
        for num in Array(fleetPeripherals.keys) { forget(radio: num) }
        for id in pendingPeripherals { central.forget(id); links[id] = nil }
        pendingPeripherals.removeAll()
        pairingPeripheralId = nil
        resetSingleRadioDefaults()
        refreshFacade()
    }

    private func resetSingleRadioDefaults() {
        defaults.removeObject(forKey: Keys.peripheralId)
        myNodeNum = 0
        defaults.set(0, forKey: Keys.myNodeNum)
        defaults.set(false, forKey: Keys.loraReceived)
        loRa = LoRaSnapshot()
        Task { await store?.setLocalNodeNums([]) }
    }

    // MARK: - Connection lifecycle

    /// User chose to disconnect (without forgetting the radios); persists so a
    /// relaunch doesn't silently reconnect against their wishes.
    @Published var userDisconnected: Bool = UserDefaults.standard.bool(forKey: "userDisconnected") {
        didSet { UserDefaults.standard.set(userDisconnected, forKey: "userDisconnected") }
    }

    func disconnectByUser() {
        userDisconnected = true
        central.disconnectAll(userInitiated: true)
        for link in links.values { link.watchdog?.cancel(); link.phase = .armed }
        refreshFacade()
    }

    func reconnectByUser() {
        userDisconnected = false
        connectIfNeeded()
    }

    /// If a connect attempt stalls (stale peripheral reference, missed
    /// callback), tear it down and retry fresh every 20 s while connecting.
    private func armWatchdog(_ link: RadioLink) {
        link.watchdog?.cancel()
        link.watchdog = Task { [weak self, weak link] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, let link, !Task.isCancelled, link.phase == .connecting,
                  self.links[link.id] === link else { return }
            self.log.warning("connect watchdog: retrying fresh \(link.id.uuidString.prefix(8))")
            self.central.retryFresh(id: link.id)
            self.armWatchdog(link)
        }
    }

    /// Arm pending connects for every fleet radio not already linked.
    func connectIfNeeded() {
        guard bluetoothOn, !userDisconnected else { return }
        var ids: Set<UUID> = []
        for id in wantedPeripheralIds {
            let link = links[id] ?? RadioLink(id: id)
            links[id] = link
            guard link.phase == .armed || link.phase == .bondLost else { continue }
            link.phase = .connecting
            armWatchdog(link)
            ids.insert(id)
        }
        if !ids.isEmpty { central.connect(to: ids) }
        refreshFacade()
    }

    private func handle(_ event: BLECentral.Event) {
        switch event {
        case .bluetoothState(let cbState):
            bluetoothOn = cbState == .poweredOn
            if bluetoothOn {
                if pairingInProgress { central.startScan() }
                connectIfNeeded()
            }
            refreshFacade()

        case .discovered(let device):
            guard pairingInProgress, !wantedPeripheralIds.contains(device.id) else { return }
            if let index = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[index].rssi = device.rssi
            } else {
                discovered.append(device)
            }
            discovered.sort { $0.rssi > $1.rssi }

        case .linkReady(let id):
            let link = links[id] ?? RadioLink(id: id)
            links[id] = link
            link.watchdog?.cancel()
            link.phase = .syncing
            refreshFacade()
            startHandshake(link)

        case .disconnected(let id, let userInitiated):
            let old = links[id]
            old?.watchdog?.cancel()
            links[id] = nil
            if wantedPeripheralIds.contains(id) {
                let link = RadioLink(id: id)
                links[id] = link
                // Re-arm the pending connect on every non-user disconnect —
                // this is what lets iOS relaunch us when the radio comes
                // back in range.
                if !userInitiated, bluetoothOn, !userDisconnected {
                    link.phase = .armed
                    central.connect(to: [id])
                }
            }
            if let old, old.nodeNum > 0 {
                noteAppEvent("radio \(String(format: "!%08x", UInt32(truncatingIfNeeded: old.nodeNum))) disconnected")
            }
            refreshFacade()

        case .bondLost(let id):
            links[id]?.phase = .bondLost
            refreshFacade()
            NotificationManager.shared.postBondLost()

        case .writeError(let id, let message):
            logTraffic(from: links[id]?.nodeNum ?? myNodeNum, port: "ble", summary: "Write to radio failed: \(message)")

        case .writeStalled(let id, let pending):
            logTraffic(from: links[id]?.nodeNum ?? myNodeNum, port: "ble",
                       summary: "Write to radio stalled — \(pending) queued, pump reset")

        case .frame(let id, let data):
            guard let link = links[id] else { return }
            process(frame: data, link: link)

        case .drainComplete(let id):
            if let link = links[id], link.phase == .connected {
                touchLastSynced(link)
            }
        }
    }

    // MARK: - Facade over the fleet

    private func deriveState() -> State {
        if wantedPeripheralIds.isEmpty { return .noRadio }
        if !bluetoothOn { return .bluetoothOff }
        let phases = links.values.map(\.phase)
        if phases.contains(.connected) { return .connected }
        if phases.contains(.syncing) { return .syncing }
        if phases.contains(.connecting) { return .connecting }
        if phases.contains(.bondLost) { return .bondLost }
        return .offline
    }

    /// Republish everything the app reads as "the radio" from the transmit
    /// radio (or the best link we have), and the attached list.
    private func refreshFacade() {
        let transmit = transmitLink
        if let link = transmit {
            if myNodeNum != link.nodeNum {
                myNodeNum = link.nodeNum
                defaults.set(myNodeNum, forKey: Keys.myNodeNum)
            }
            if !link.firmwareVersion.isEmpty, firmwareVersion != link.firmwareVersion {
                firmwareVersion = link.firmwareVersion
                defaults.set(firmwareVersion, forKey: Keys.firmware)
            }
            if link.loRa.received, loRa != link.loRa {
                loRa = link.loRa
                persistLoRa()
            }
            bluetoothConfig = link.bluetoothConfig
            deviceConfig = link.deviceConfig
            displayConfig = link.displayConfig
            positionConfig = link.positionConfig
            telemetryConfig = link.telemetryConfig
            connectedAt = link.connectedAt
            if let synced = link.lastSyncedAt { lastSyncedAt = synced }
        } else {
            connectedAt = nil
        }
        let newState = deriveState()
        if state != newState { state = newState }
        let list = links.values
            .filter { $0.phase != .armed }
            .sorted { fleetPriority($0.nodeNum) < fleetPriority($1.nodeNum) }
            .map { AttachedRadio(id: $0.id, nodeNum: $0.nodeNum, phase: $0.phase,
                                 firmware: $0.firmwareVersion, isTransmit: $0 === transmit, drift: $0.drift,
                                 roleRaw: $0.deviceConfig.map { Int($0.role.rawValue) }) }
        if attached != list { attached = list }
    }

    // MARK: - Handshake (messages first, node DB deferred) — per link

    private func startHandshake(_ link: RadioLink) {
        link.knownPeers.removeAll()
        link.preloadedThisSession.removeAll()
        link.nodeDBRequested = false
        var heartbeat = ToRadio()
        heartbeat.heartbeat = Heartbeat()
        write(heartbeat, via: link)

        var wantConfig = ToRadio()
        wantConfig.wantConfigID = 69420   // NONCE_ONLY_CONFIG
        write(wantConfig, via: link)
        central.drain(id: link.id)
    }

    private func handleConfigComplete(_ nonce: UInt32, link: RadioLink) {
        switch nonce {
        case 69420:
            link.phase = .connected
            let now = Date()
            link.connectedAt = now
            // Previous sync → now: the span the radio spent without us. A
            // first-ever connect trusts nothing (its clock was never set).
            if let previous = link.lastSyncedAt, previous <= now {
                link.trustedRxWindow = previous...now
            } else {
                link.trustedRxWindow = nil
            }
            touchLastSynced(link)
            setRadioTime(via: link)
            refreshFacade()
            noteAppEvent("radio \(String(format: "!%08x", UInt32(truncatingIfNeeded: link.nodeNum))) attached\(link === transmitLink ? " (transmit)" : "")")
            if link === transmitLink {
                needsMeshSetup = loRa.received && loRa.regionRaw == Config.LoRaConfig.RegionCode.unset.rawValue
            }
            flushOutboxAndSweep()
            startOutboxSweep()
            requestStoreForwardHistoryIfUseful()
            announcePresenceIfDue()
            Task { await self.computeDrift(link) }
            // Friendly default name for a blank primary channel: the applied
            // metro's name ("NYC Mesh"), handled store-side only when unnamed.
            if let id = MetroPresetStore.shared.appliedPresetId,
               let preset = MetroPresetStore.shared.allPresets.first(where: { $0.id == id }),
               let store {
                let shortName = preset.name.components(separatedBy: " (").first ?? preset.name
                Task { await store.setPrimaryChannelName(ifUnnamed: shortName) }
            }
            // Node DB is deliberately deferred: on a big mesh it can take minutes and
            // messages must never wait behind it.
            Task { @MainActor [weak link] in
                try? await Task.sleep(for: .seconds(2))
                if let link { self.requestNodeDBIfNeeded(link) }
            }
        case 69421:
            touchLastSynced(link)
        default:
            break
        }
    }

    private func requestNodeDBIfNeeded(_ link: RadioLink) {
        guard link.phase == .connected, !link.nodeDBRequested else { return }
        link.nodeDBRequested = true
        var toRadio = ToRadio()
        toRadio.wantConfigID = 69421      // NONCE_ONLY_DB
        write(toRadio, via: link)
        central.drain(id: link.id)
    }

    private var outboxTimer: Task<Void, Never>?

    private func startOutboxSweep() {
        outboxTimer?.cancel()
        outboxTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.state == .connected else { continue }
                self.flushOutboxAndSweep()
            }
        }
    }

    private func flushOutboxAndSweep() {
        guard let store else { return }
        Task {
            let queued = await store.drainOutbox()
            for record in queued {
                await MainActor.run { self.transmit(record) }
            }
            let attachedNow = Set(self.attachedNodeNums)
            let reholds = await store.sweepStaleSending(attachedRadios: attachedNow)
            for packetId in reholds {
                await store.prepareRetryHold(packetId: packetId,
                                             newPacketId: Int64(self.newPacketId()))
            }
        }
    }

    private func touchLastSynced(_ link: RadioLink) {
        let now = Date()
        link.lastSyncedAt = now
        if link.nodeNum > 0 { defaults.set(now, forKey: "\(Keys.lastSynced)-\(link.nodeNum)") }
        if link === transmitLink || transmitLink == nil {
            lastSyncedAt = now
            defaults.set(now, forKey: Keys.lastSynced)
        }
    }

    // MARK: - Fleet settings (docs/MULTI_RADIO.md §1.5)

    /// How `link` differs from the fleet: the store's channel list (what the
    /// transmit radio carries) and the transmit radio's LoRa settings.
    func computeDrift(_ link: RadioLink) async {
        guard let store, link.nodeNum > 0 else { return }
        guard let transmit = transmitLink, transmit !== link else {
            link.drift = []
            refreshFacade()
            return
        }
        let fleetChannels = await store.channelSettings()
        var lines: [String] = []
        for ch in fleetChannels {
            let name = ch.name.isEmpty ? (ch.index == 0 ? "primary channel" : "channel \(ch.index)") : "\"\(ch.name)\""
            if let mine = link.channels[ch.index], mine.roleRaw != 0 {
                if mine.name != ch.name { lines.append("Slot \(ch.index) is named \"\(mine.name)\", fleet has \(name)") }
                else if mine.psk != ch.psk { lines.append("\(name.capitalized) has a different key") }
            } else {
                lines.append("Missing \(name) (slot \(ch.index))")
            }
        }
        for (index, mine) in link.channels where mine.roleRaw != 0 && !fleetChannels.contains(where: { $0.index == index }) {
            lines.append("Extra channel \"\(mine.name)\" in slot \(index) not in the fleet")
        }
        if link.loRa.received, transmit.loRa.received {
            if link.loRa.regionRaw != transmit.loRa.regionRaw { lines.append("Region differs (\(link.loRa.regionName) vs \(transmit.loRa.regionName))") }
            if link.loRa.presetRaw != transmit.loRa.presetRaw { lines.append("Modem preset differs (\(link.loRa.presetName) vs \(transmit.loRa.presetName))") }
            if link.loRa.frequencySlot != transmit.loRa.frequencySlot { lines.append("Frequency slot \(link.loRa.frequencySlot) vs \(transmit.loRa.frequencySlot)") }
            if link.loRa.hopLimit != transmit.loRa.hopLimit { lines.append("Hop limit \(link.loRa.hopLimit) vs \(transmit.loRa.hopLimit)") }
        }
        link.drift = lines
        if !lines.isEmpty {
            noteAppEvent("radio \(String(format: "!%08x", UInt32(truncatingIfNeeded: link.nodeNum))) differs from the fleet: \(lines.count) item(s)")
        }
        refreshFacade()
    }

    private func link(forNodeNum num: Int64) -> RadioLink? {
        links.values.first { $0.nodeNum == num && $0.phase == .connected }
    }

    /// Write the fleet's channels and LoRa settings to one attached radio.
    /// Never touches the security section or the role (docs §1.5).
    func applyFleetSettings(to nodeNum: Int64) {
        guard let store, let link = link(forNodeNum: nodeNum), let transmit = transmitLink, transmit !== link else { return }
        Task {
            let channels = await store.channelSettings()
            for ch in channels {
                var settings = ChannelSettings()
                settings.name = ch.name
                settings.psk = ch.psk
                var channel = Channel()
                channel.index = ch.index
                channel.role = ch.index == 0 ? .primary : .secondary
                channel.settings = settings
                var admin = AdminMessage()
                admin.setChannel = channel
                sendAdmin(admin, via: link)
            }
            // Disable slots the fleet doesn't use.
            for (index, mine) in link.channels where mine.roleRaw != 0 && !channels.contains(where: { $0.index == index }) {
                var channel = Channel()
                channel.index = index
                channel.role = .disabled
                var admin = AdminMessage()
                admin.setChannel = channel
                sendAdmin(admin, via: link)
            }
            if transmit.loRa.received {
                var lora = Config.LoRaConfig()
                lora.usePreset = true
                lora.region = Config.LoRaConfig.RegionCode(rawValue: transmit.loRa.regionRaw) ?? .us
                lora.modemPreset = Config.LoRaConfig.ModemPreset(rawValue: transmit.loRa.presetRaw) ?? .longFast
                lora.channelNum = UInt32(transmit.loRa.frequencySlot)
                lora.hopLimit = UInt32(transmit.loRa.hopLimit)
                lora.txEnabled = true
                var config = Config()
                config.lora = lora
                var admin = AdminMessage()
                admin.setConfig = config
                sendAdmin(admin, via: link)   // the radio reboots; the link re-syncs
            }
            link.drift = []
            noteAppEvent("applied fleet settings to \(String(format: "!%08x", UInt32(truncatingIfNeeded: nodeNum)))")
            refreshFacade()
        }
    }

    /// Owner names for one attached fleet radio (suggestion accepted).
    func setOwner(longName: String, shortName: String, via nodeNum: Int64) {
        guard let link = link(forNodeNum: nodeNum), let store else { return }
        let long = MeshName.clampLong(longName.trimmingCharacters(in: .whitespaces))
        let short = MeshName.clampShort(shortName.trimmingCharacters(in: .whitespaces))
        guard !long.isEmpty, !short.isEmpty else { return }
        var user = User()
        user.longName = long
        user.shortName = short
        var admin = AdminMessage()
        admin.setOwner = user
        sendAdmin(admin, via: link)
        Task { await store.renameNode(num: nodeNum, longName: long, shortName: short) }
    }

    /// Device role for one attached fleet radio (suggestion accepted); written
    /// on top of that radio's own device config so nothing else changes.
    func setDeviceRole(_ roleRaw: Int, via nodeNum: Int64) {
        guard let link = link(forNodeNum: nodeNum), var device = link.deviceConfig else { return }
        device.role = Config.DeviceConfig.Role(rawValue: roleRaw) ?? .client
        var config = Config()
        config.device = device
        var admin = AdminMessage()
        admin.setConfig = config
        sendAdmin(admin, via: link)
        link.deviceConfig = device
    }

    /// Forget & Revoke (docs §1.8): drop the radio, then give every
    /// custom-keyed channel a fresh key on the transmit radio. Other fleet
    /// radios show drift until re-applied; channels on the default key
    /// (a community mesh) can't be revoked. Returns the rotated channel
    /// names so the UI can say who needs the new QR.
    @discardableResult
    func forgetAndRevoke(radio nodeNum: Int64) -> [String] {
        forget(radio: nodeNum)
        return rotateFleetChannelKeys()
    }

    @discardableResult
    func rotateFleetChannelKeys() -> [String] {
        guard let store else { return [] }
        var rotated: [String] = []
        Task {
            for ch in await store.channelSettings() where ch.psk.count >= 16 {
                let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                setChannel(index: ch.index, name: ch.name, roleRaw: ch.roleRaw, psk: fresh)
                rotated.append(ch.name.isEmpty ? "channel \(ch.index)" : ch.name)
            }
            if !rotated.isEmpty {
                noteAppEvent("rotated keys on \(rotated.joined(separator: ", ")) — re-share the QR")
            }
            for link in links.values where link.phase == .connected { await computeDrift(link) }
        }
        return rotated
    }

    /// Node numbers of every attached (connected) fleet radio, transmit first.
    var attachedNodeNums: [Int64] {
        attached.filter { $0.phase == .connected && $0.nodeNum > 0 }.map(\.nodeNum)
    }

    /// First MyInfo on a link: it is now a known fleet radio on this phone.
    private func registerFleetRadio(_ num: Int64, link: RadioLink) {
        fleetPeripherals[num] = link.id
        pendingPeripherals.remove(link.id)
        if pairingPeripheralId == link.id { pairedNodeNum = num }
        // Per-radio sync clock; fall back to the pre-fleet single value.
        link.lastSyncedAt = defaults.object(forKey: "\(Keys.lastSynced)-\(num)") as? Date
            ?? (num == defaults.integer(forKey: Keys.myNodeNum) ? lastSyncedAt : nil)
        if myNodeNum == 0 {
            myNodeNum = num
            defaults.set(num, forKey: Keys.myNodeNum)
        }
        let firmware = link.firmwareVersion
        Task {
            await store?.upsertRadio(nodeNum: num, firmware: firmware.isEmpty ? nil : firmware, publicKey: nil, battery: nil)
            await reloadFleet()
        }
    }

    // MARK: - Inbound frames (per link)

    private func process(frame: Data, link: RadioLink) {
        guard let fromRadio = try? FromRadio(serializedBytes: frame) else {
            log.error("undecodable FromRadio frame (\(frame.count) bytes)")
            return
        }
        let isPrimary = transmitLink == nil || transmitLink === link
        switch fromRadio.payloadVariant {
        case .myInfo(let myInfo):
            let num = Int64(myInfo.myNodeNum)
            if link.nodeNum != num {
                link.nodeNum = num
                registerFleetRadio(num, link: link)
            }

        case .metadata(let metadata):
            link.firmwareVersion = metadata.firmwareVersion
            if link.nodeNum > 0 {
                let num = link.nodeNum, fw = metadata.firmwareVersion
                Task { await store?.upsertRadio(nodeNum: num, firmware: fw, publicKey: nil, battery: nil) }
            }
            if isPrimary { refreshFacade() }

        case .config(let config):
            switch config.payloadVariant {
            case .bluetooth(let bluetooth): link.bluetoothConfig = bluetooth
            case .device(let device): link.deviceConfig = device
            case .display(let display): link.displayConfig = display
            case .position(let position): link.positionConfig = position
            default: break
            }
            if case .lora(let lora) = config.payloadVariant {
                link.loRa = LoRaSnapshot(received: true,
                                         regionRaw: lora.region.rawValue,
                                         presetRaw: lora.modemPreset.rawValue,
                                         frequencySlot: Int(lora.channelNum),
                                         hopLimit: Int(lora.hopLimit))
                if isPrimary {
                    // If the radio's config matches a known metro preset but we never
                    // recorded applying it (applied before tracking existed, or via
                    // another app), adopt it — this drives the channel icon.
                    MetroPresetStore.shared.inferAppliedPreset(regionRaw: link.loRa.regionRaw,
                                                               presetRaw: link.loRa.presetRaw,
                                                               frequencySlot: link.loRa.frequencySlot)
                }
            }
            if isPrimary { refreshFacade() }

        case .moduleConfig(let moduleConfig):
            if case .telemetry(let telemetry) = moduleConfig.payloadVariant {
                link.telemetryConfig = telemetry
                if isPrimary { refreshFacade() }
            }

        case .channel(let channel):
            // Every link remembers its own table (for drift); the store's
            // fleet-wide list is defined by the transmit radio's dump.
            link.channels[Int32(channel.index)] = MessageStore.ChannelSnapshot(
                index: Int32(channel.index), name: channel.settings.name,
                psk: channel.settings.psk, roleRaw: Int32(channel.role.rawValue))
            if isPrimary { Task { await store?.applyChannel(channel) } }

        case .nodeInfo(let nodeInfo):
            link.knownPeers.insert(Int64(nodeInfo.num))
            Task { await store?.applyNodeInfo(nodeInfo) }

        case .configCompleteID(let nonce):
            handleConfigComplete(nonce, link: link)

        case .rebooted:
            // Radio rebooted mid-session (e.g. after a config write): full re-sync.
            link.phase = .syncing
            refreshFacade()
            startHandshake(link)

        case .packet(let packet):
            handleMeshPacket(packet, via: link)

        case .queueStatus(let qs):
            // The firmware's verdict on every packet the phone hands it:
            // res is the sendLocal error code, free/maxlen the TX queue.
            // A packet the firmware couldn't even decode never gets one.
            logTraffic(from: link.nodeNum, port: "queue",
                       summary: "res=\(qs.res) free=\(qs.free)/\(qs.maxlen) for #\(String(format: "%08X", qs.meshPacketID))")

        default:
            break
        }
    }

    private func handleMeshPacket(_ packet: MeshPacket, via link: RadioLink) {
        guard let store else { return }
        let fromNum = Int64(packet.from)
        link.knownPeers.insert(fromNum)
        if !isMine(fromNum) {
            TrafficMonitor.shared.noteMeshPacket()
            accumulateCoverage(snr: packet.rxSnr)
            Task {
                await store.heard(num: fromNum, snr: packet.rxSnr,
                                  hopStart: packet.hopStart, hopLimit: packet.hopLimit,
                                  rxTime: packet.rxTime)
                // Their radio is alive — anything held for them goes out now.
                let released = await store.releaseWaitingForPeer(fromNum)
                if !released.isEmpty {
                    await MainActor.run {
                        for record in released { self.transmit(record) }
                    }
                }
            }
        }
        let hops = packet.hopStart > 0 && packet.hopStart >= packet.hopLimit
            ? Int(packet.hopStart - packet.hopLimit) : -1
        guard case .decoded(let decoded) = packet.payloadVariant else {
            logTraffic(from: fromNum, port: "encrypted", summary: "Undecodable (no matching channel key)",
                       snr: packet.rxSnr, hopsAway: hops)
            return
        }
        if decoded.portnum == .textMessageApp, fromNum != myNodeNum {
            TrafficMonitor.shared.noteTextMessage()
        }
        notePresenceHeard(fromNum, hops: hops)
        logTraffic(from: fromNum, port: portLabel(decoded.portnum), summary: trafficSummary(decoded),
                   snr: packet.rxSnr, hopsAway: hops)

        switch decoded.portnum {
        case .textMessageApp, .detectionSensorApp, .alertApp:
            let myNum = link.nodeNum > 0 ? link.nodeNum : myNodeNum
            let window = link.trustedRxWindow
            let via = link.nodeNum
            Task {
                if let inbound = await store.ingestTextMessage(packet: packet, myNum: myNum,
                                                               trustedRxWindow: window,
                                                               viaNodeNum: via) {
                    await MainActor.run { self.notifyIfAppropriate(inbound) }
                }
                let unread = await store.totalUnreadConversations()
                await NotificationManager.shared.setBadge(unread)
            }

        case .routingApp:
            guard decoded.requestID != 0, let routing = try? Routing(serializedBytes: decoded.payload) else { return }
            // Only routing results addressed to us correlate with our sends —
            // overheard results for other nodes' packets could collide on the
            // 32-bit id space and forge a delivery state.
            guard isMine(Int64(packet.to)) else { return }
            let errorRaw = Int32(routing.errorReason.rawValue)
            if let waiter = pendingAdminAcks.removeValue(forKey: decoded.requestID) {
                waiter.resume(returning: errorRaw == 0)
            }
            if let key = resendRequests.first(where: { $0.value.packetId == decoded.requestID })?.key {
                if errorRaw == 0 { resendRequests[key]?.delivered = true } else { resendRequests[key]?.nakError = errorRaw }
            }
            if let pending = pendingOwner, pending.packetId == decoded.requestID {
                pendingOwner = nil
                if errorRaw != 0 {
                    log.error("set_owner NAK (\(String(describing: routing.errorReason))) — restoring previous names")
                    Task {
                        await store.renameNode(num: myNodeNum, longName: pending.previousLong,
                                               shortName: pending.previousShort)
                    }
                }
            }
            #if MESHSITES
            // Chunk pacing: any routing result for a Meshsites packet id
            // releases the server's ack wait (no-op for other packet ids);
            // a NAK aborts the remaining chunks.
            MeshsiteServer.shared.noteAck(requestId: decoded.requestID, ok: errorRaw == 0)
            // Client side: the same routing result tells the browser whether
            // its request ever left the radio (powers the timeout diagnosis).
            MeshsitesManager.shared.noteRequestRouting(packetId: decoded.requestID,
                                                       errorRaw: errorRaw)
            #endif
            let requestId = Int64(decoded.requestID)
            Task {
                // The Live Activity mirrors the store's verdict — it must
                // never claim delivery on evidence the store would reject.
                let outcome = await store.applyRoutingResult(requestId: decoded.requestID,
                                                             errorRaw: errorRaw,
                                                             ackFrom: Int64(packet.from),
                                                             ackTo: Int64(packet.to))
                guard let outcome else { return }
                await MainActor.run {
                    // PKI 39: the radio has no key for this peer after all —
                    // forget what we assumed so the next send preloads first.
                    if errorRaw == 39 || errorRaw == 34 {
                        for l in self.links.values {
                            l.knownPeers.remove(outcome.toNum)
                            l.preloadedThisSession.remove(outcome.toNum)
                        }
                    }
                    switch MessageStatus(rawValue: outcome.statusRaw) {
                    case .failed:
                        LiveActivityManager.shared.update(packetId: requestId,
                                                          status: "Couldn't deliver", phase: 3, final: true)
                    case .deliveredToRadio:
                        LiveActivityManager.shared.update(packetId: requestId,
                                                          status: "Delivered to their radio", phase: 2, final: true)
                    case .sentToMesh:
                        LiveActivityManager.shared.update(packetId: requestId,
                                                          status: "Sent to mesh", phase: 2, final: true)
                    case .relayed:
                        LiveActivityManager.shared.update(packetId: requestId,
                                                          status: "Relayed by the mesh…", phase: 1, final: false)
                    default:
                        break
                    }
                }
            }

        case .positionApp:
            guard let position = try? Position(serializedBytes: decoded.payload) else { return }
            if isMine(fromNum), position.latitudeI != 0 || position.longitudeI != 0 {
                myLastPosition = (Double(position.latitudeI) * 1e-7,
                                  Double(position.longitudeI) * 1e-7, Date())
            }
            Task { await store.applyPositionPacket(position, from: fromNum) }

        case .nodeinfoApp:
            guard let user = try? User(serializedBytes: decoded.payload) else { return }
            var info = NodeInfo()
            info.num = packet.from
            info.user = user
            Task { await store.applyNodeInfo(info) }

        case .telemetryApp:
            guard let telemetry = try? Telemetry(serializedBytes: decoded.payload) else { return }
            if isMine(fromNum), case .deviceMetrics(let metrics) = telemetry.variant, metrics.hasBatteryLevel {
                let battery = Int(metrics.batteryLevel)
                Task {
                    await store.upsertRadio(nodeNum: fromNum, firmware: nil, publicKey: nil, battery: battery)
                    await self.reloadFleet()
                }
            }
            Task { await store.applyTelemetry(telemetry, from: fromNum) }

        case .tracerouteApp:
            handleTracerouteReply(packet, from: fromNum)

        case .waypointApp:
            guard let waypoint = try? Waypoint(serializedBytes: decoded.payload) else { return }
            Task { await store.applyWaypoint(waypoint, from: fromNum) }

        case .storeForwardApp:
            guard let sf = try? StoreAndForward(serializedBytes: decoded.payload) else { return }
            switch sf.rr {
            case .routerHeartbeat:
                sfRouterNum = fromNum
                sfRouterHeardAt = Date()
            case .routerTextDirect, .routerTextBroadcast:
                // History replay: the router preserves the original sender in `from`.
                guard let text = String(data: sf.text, encoding: .utf8) else { return }
                let myNum = myNodeNum
                let isBroadcast = sf.rr == .routerTextBroadcast
                let channel = Int32(packet.channel)
                Task {
                    if let inbound = await store.ingestStoreForwardText(
                        from: fromNum, text: text, isBroadcast: isBroadcast,
                        channel: channel, myNum: myNum) {
                        await MainActor.run { self.notifyIfAppropriate(inbound) }
                    }
                }
            default:
                break
            }

        case .neighborinfoApp:
            guard let info = try? NeighborInfo(serializedBytes: decoded.payload) else { return }
            let reporter = Int64(info.nodeID)
            var edges = neighborEdges.filter { $0.from != reporter }
            for neighbor in info.neighbors {
                edges.append(NeighborEdge(from: reporter, to: Int64(neighbor.nodeID), snr: neighbor.snr))
            }
            neighborEdges = Array(edges.suffix(300))

        case .adminApp:
            // Read-backs: the radio's answers to getConfig/getModuleConfig requests.
            guard let admin = try? AdminMessage(serializedBytes: decoded.payload) else { return }
            switch admin.payloadVariant {
            case .getModuleConfigResponse(let moduleConfig):
                if case .telemetry(let telemetry) = moduleConfig.payloadVariant {
                    telemetryConfig = telemetry
                }
            case .getConfigResponse(let config):
                switch config.payloadVariant {
                case .bluetooth(let bluetooth): bluetoothConfig = bluetooth
                case .device(let device): deviceConfig = device
                case .display(let display): displayConfig = display
                case .position(let position): positionConfig = position
                case .lora(let lora):
                    loRa = LoRaSnapshot(received: true,
                                        regionRaw: lora.region.rawValue,
                                        presetRaw: lora.modemPreset.rawValue,
                                        frequencySlot: Int(lora.channelNum),
                                        hopLimit: Int(lora.hopLimit))
                    persistLoRa()
                default: break
                }
            default:
                break
            }

        default:
            if case .UNRECOGNIZED(Self.reliabilityPort) = decoded.portnum,
               Int64(packet.to) == myNodeNum {
                handleReliabilityFrame(from: fromNum, payload: decoded.payload)
                break
            }
            #if MESHSITES
            if case .UNRECOGNIZED(MeshsitesManager.port) = decoded.portnum {
                MeshsitesManager.shared.handle(from: fromNum, to: Int64(packet.to),
                                               payload: decoded.payload,
                                               hopStart: packet.hopStart, hopLimit: packet.hopLimit)
            }
            #endif
            break
        }
    }

    private func portLabel(_ port: PortNum) -> String {
        #if MESHSITES
        if case .UNRECOGNIZED(MeshsitesManager.port) = port { return "meshsite" }
        #endif
        if case .UNRECOGNIZED(Self.reliabilityPort) = port { return "resend" }
        switch port {
        case .textMessageApp: return "message"
        case .positionApp: return "position"
        case .nodeinfoApp: return "nodeinfo"
        case .routingApp: return "routing"
        case .telemetryApp: return "telemetry"
        case .waypointApp: return "waypoint"
        case .tracerouteApp: return "traceroute"
        case .adminApp: return "admin"
        case .neighborinfoApp: return "neighbors"
        case .storeForwardApp: return "store&forward"
        default: return String(describing: port)
        }
    }

    private func trafficSummary(_ decoded: DataMessage) -> String {
        switch decoded.portnum {
        case .textMessageApp, .detectionSensorApp, .alertApp:
            return String((String(data: decoded.payload, encoding: .utf8) ?? "<binary>").prefix(80))
        case .positionApp:
            if let position = try? Position(serializedBytes: decoded.payload),
               position.latitudeI != 0 || position.longitudeI != 0 {
                return String(format: "%.4f, %.4f", Double(position.latitudeI) * 1e-7, Double(position.longitudeI) * 1e-7)
            }
            return "Position update"
        case .nodeinfoApp:
            if let user = try? User(serializedBytes: decoded.payload) {
                return "\(user.longName) (\(user.shortName))"
            }
            return "Node info"
        case .routingApp:
            if let routing = try? Routing(serializedBytes: decoded.payload) {
                return routing.errorReason == .none
                    ? "ACK for #\(decoded.requestID)"
                    : "NAK (\(String(describing: routing.errorReason))) for #\(decoded.requestID)"
            }
            return "Routing"
        case .telemetryApp:
            if let telemetry = try? Telemetry(serializedBytes: decoded.payload),
               case .deviceMetrics(let metrics) = telemetry.variant, metrics.hasBatteryLevel {
                return "Battery \(metrics.batteryLevel > 100 ? "plugged in" : "\(metrics.batteryLevel)%")"
            }
            return "Telemetry"
        case .waypointApp:
            if let waypoint = try? Waypoint(serializedBytes: decoded.payload), !waypoint.name.isEmpty {
                return "Waypoint: \(waypoint.name)"
            }
            return "Waypoint"
        default:
            #if MESHSITES
            if decoded.portnum.rawValue == MeshsitesManager.port {
                return MeshsitesManager.describeFrame([UInt8](decoded.payload))
            }
            #endif
            if decoded.portnum.rawValue == Self.reliabilityPort {
                return Self.describeReliability([UInt8](decoded.payload))
            }
            return "\(decoded.payload.count) bytes"
        }
    }

    private func notifyIfAppropriate(_ inbound: MessageStore.InboundMessage) {
        guard !inbound.isTapback else { return }
        switch NotifyLevel(rawValue: inbound.notifyLevelRaw) ?? .all {
        case .muted: return
        case .mentionsOnly: guard inbound.isMention else { return }
        case .all: break
        }
        if UIStateObserver.shared.isActive && activeConversationKey == inbound.conversationKey { return }
        let prefs = UserDefaults.standard
        if inbound.isDM {
            guard prefs.boolWithDefault("notifyDMs", true) else { return }
        } else {
            guard prefs.boolWithDefault("notifyChannels", true) else { return }
        }
        NotificationManager.shared.postMessage(inbound)
    }

    // MARK: - Outgoing

    private func newPacketId() -> UInt32 {
        UInt32.random(in: 0x100..<UInt32.max)
    }

    func sendText(_ text: String, to destination: MessageDestinationRef,
                  isEmoji: Bool = false, replyId: Int64 = 0, holdForPeer: Bool = false) {
        guard let store else { return }
        let packetId = newPacketId()
        let connected = state == .connected || state == .syncing
        let myNum = myNodeNum
        // Hold is explicit (long-press Send); a plain tap always transmits now.
        var hold = holdForPeer
        if case .node = destination {} else { hold = false }
        let shouldHold = hold
        Task {
            let record = await store.persistOutgoing(packetId: Int64(packetId), myNum: myNum,
                                                     destination: destination, text: text,
                                                     isEmoji: isEmoji, replyId: replyId,
                                                     connected: connected, holdForPeer: shouldHold)
            if shouldHold { return }
            if connected, !isEmoji {
                await MainActor.run { self.transmit(record) }
                // The delivery drama, live — DMs and channel sends alike.
                switch destination {
                case .node(let num):
                    let snapshot = await store.nodeSnapshot(num: num)
                    await MainActor.run {
                        LiveActivityManager.shared.start(packetId: Int64(packetId),
                                                         peerName: snapshot?.longName ?? "Mesh node",
                                                         preview: text)
                    }
                case .channel(let index):
                    let title = await store.fetchConversationTitle(key: ConversationEntity.channelKey(index)) ?? "Channel \(index)"
                    await MainActor.run {
                        LiveActivityManager.shared.start(packetId: Int64(packetId),
                                                         peerName: title, preview: text, isChannel: true)
                    }
                }
            } else if connected {
                await MainActor.run { self.transmit(record) }
            }
        }
    }

    /// User override on a held (send-when-reachable) message. Connected →
    /// transmit immediately; otherwise demote to the outbox so the next
    /// connection sends it — never a silent no-op.
    func forceSendNow(packetId: Int64) {
        guard let store else { return }
        if state == .connected || state == .syncing {
            Task {
                if let record = await store.recordForceSend(packetId: packetId) {
                    await MainActor.run { self.transmit(record) }
                }
            }
        } else {
            Task { await store.demoteHeldToOutbox(packetId: packetId) }
        }
    }

    /// Retry-as-hold: park the failed message until the peer's radio is heard.
    func retryWhenPeerSeen(packetId: Int64) {
        guard let store else { return }
        let newId = newPacketId()
        Task { await store.prepareRetryHold(packetId: packetId, newPacketId: Int64(newId)) }
    }

    func retry(packetId: Int64) {
        guard let store else { return }
        // The old packet id's Live Activity can never resolve (the id is
        // retired) — end it now instead of letting the safety net misreport.
        LiveActivityManager.shared.update(packetId: packetId,
                                          status: "Retrying…", phase: 1, final: true)
        let newId = newPacketId()
        let connected = state == .connected
        Task {
            if let record = await store.prepareRetry(packetId: packetId, newPacketId: Int64(newId), connected: connected) {
                await MainActor.run { self.transmit(record) }
            }
        }
    }

    /// Read-state changes route through the shared store actor (a second
    /// actor on the same rows races ingest) and refresh the app badge.
    func markConversationRead(key: String) {
        guard let store else { return }
        Task {
            await store.markConversationRead(key: key)
            let unread = await store.totalUnreadConversations()
            await NotificationManager.shared.setBadge(unread)
        }
    }

    func refreshBadge() {
        guard let store else { return }
        Task {
            // Brief pause lets a main-context save land before the count.
            try? await Task.sleep(for: .milliseconds(500))
            let unread = await store.totalUnreadConversations()
            await NotificationManager.shared.setBadge(unread)
        }
    }

    /// Kill switch for the sequence trailer (Settings › Data), default on.
    static var sequenceTrailerEnabled: Bool {
        UserDefaults.standard.object(forKey: "sequenceTrailerEnabled") as? Bool ?? true
    }

    /// DMs to a peer the radio hasn't shown us get their node info loaded
    /// onto the radio first (issue #1 follow-up, docs/MULTI_RADIO.md §1.3).
    private func transmit(_ record: MessageStore.OutgoingRecord) {
        let isDM = record.toNum != Int64(UInt32.max)
        guard isDM, let link = transmitLink,
              !link.knownPeers.contains(record.toNum), !link.preloadedThisSession.contains(record.toNum) else {
            transmitNow(record)
            return
        }
        Task {
            await preloadContact(peer: record.toNum)
            transmitNow(record)
        }
    }

    /// add_contact + set_favorite_node for `peer` from our own store, then
    /// wait for the radio's ack (or 2 s). Favorite so the radio's eviction
    /// policy spares the entry. At most once per peer per session — each
    /// add_contact is a flash write on the radio.
    func preloadContact(peer: Int64) async {
        guard let store, let link = transmitLink, peer > 0, !isMine(peer) else { return }
        link.preloadedThisSession.insert(peer)
        guard let snapshot = await store.nodeSnapshot(num: peer) else { return }
        var user = User()
        user.id = String(format: "!%08x", UInt32(truncatingIfNeeded: peer))
        user.longName = snapshot.longName
        user.shortName = snapshot.shortName
        if snapshot.publicKey.count == 32 { user.publicKey = snapshot.publicKey }
        var contact = SharedContact()
        contact.nodeNum = UInt32(truncatingIfNeeded: peer)
        contact.user = user
        var admin = AdminMessage()
        admin.addContact = contact
        let id = sendAdmin(admin)
        let acked = await awaitAdminAck(id, timeout: 2)
        if acked {
            var favorite = AdminMessage()
            favorite.setFavoriteNode = UInt32(truncatingIfNeeded: peer)
            sendAdmin(favorite)
            link.knownPeers.insert(peer)
        }
        noteAppEvent("preloaded \(user.id) onto the radio\(snapshot.publicKey.count == 32 ? " with key" : " (no key)")\(acked ? "" : " — no ack, sending anyway")")
    }

    private func awaitAdminAck(_ packetId: UInt32, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingAdminAcks[packetId] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let waiter = self.pendingAdminAcks.removeValue(forKey: packetId) else { return }
                waiter.resume(returning: false)
            }
        }
    }

    private func transmitNow(_ record: MessageStore.OutgoingRecord) {
        var decoded = DataMessage()
        decoded.portnum = .textMessageApp
        decoded.payload = record.text.data(using: .utf8) ?? Data()
        if record.isEmoji {
            decoded.emoji = 1
        }
        // Reliability trailer (docs/RELIABILITY.md) in Data.bitfield. The
        // firmware stores that field in ONE byte (mesh.options: int_size:8):
        // bits 0–1 are its own flags, so ours live in bits 2–7 — bit 7 marks
        // presence, bits 2–6 carry the sequence mod 32. Draft 1 used bits
        // 23–31; that overflowed the byte, nanopb rejected the whole ToRadio,
        // and the radio silently dropped every text Hops sent (TODO 182).
        if record.seqNum >= 0, !record.isEmoji, Self.sequenceTrailerEnabled {
            decoded.bitfield = (decoded.bitfield & 0x03) | 0x80 | (UInt32(record.seqNum & 0x1F) << 2)
        }
        if record.replyId > 0 {
            decoded.replyID = UInt32(truncatingIfNeeded: record.replyId)
        }

        var packet = MeshPacket()
        packet.id = UInt32(truncatingIfNeeded: record.packetId)
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = record.toNum == Int64(UInt32.max) ? UInt32.max : UInt32(truncatingIfNeeded: record.toNum)
        packet.channel = UInt32(record.channel)
        packet.wantAck = true
        packet.decoded = decoded
        if record.toNum != Int64(UInt32.max), !record.peerPublicKey.isEmpty {
            packet.pkiEncrypted = true
            packet.publicKey = record.peerPublicKey
        }

        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
        // Our side of the story in Mesh Traffic (TODO 182): until now the
        // log held only what the radio received, so a send that never left
        // the phone was indistinguishable from one the mesh ignored.
        let preview = record.text.count > 40 ? String(record.text.prefix(40)) + "…" : record.text
        let target = record.toNum == Int64(UInt32.max)
            ? "channel \(record.channel)"
            : String(format: "!%08x", UInt32(truncatingIfNeeded: record.toNum))
            + (record.peerPublicKey.isEmpty ? "" : " (PKI)")
        logTraffic(from: myNodeNum, port: "sent",
                   summary: "→ \(target) #\(String(format: "%08X", packet.id)): \(preview)")
    }

    #if MESHSITES
    /// Sends a Meshsites frame. hop_limit is pinned to 1 per spec §1 so the
    /// packet is never relayed beyond the direct RF link. Returns the packet
    /// id so the serving side can pace chunks on routing acks.
    @discardableResult
    func sendMeshsites(to num: Int64, payload: Data, wantAck: Bool = true, via nodeNum: Int64? = nil) -> UInt32 {
        let link = nodeNum.flatMap { self.link(forNodeNum: $0) }
        var decoded = DataMessage()
        decoded.portnum = PortNum.UNRECOGNIZED(MeshsitesManager.port)
        decoded.payload = payload

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: link?.nodeNum ?? myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: num)
        packet.hopLimit = 1
        packet.wantAck = wantAck
        packet.decoded = decoded

        var toRadio = ToRadio()
        toRadio.packet = packet
        if let link { write(toRadio, via: link) } else { write(toRadio) }
        logTraffic(from: link?.nodeNum ?? myNodeNum, port: "sent",
                   summary: "→ meshsite \(String(format: "!%08x", UInt32(truncatingIfNeeded: num))) #\(String(format: "%08X", packet.id)): \(MeshsitesManager.describeFrame([UInt8](payload)))")
        return packet.id
    }
    #endif

    func sendCurrentPosition(latitude: Double, longitude: Double, to destination: MessageDestinationRef) {
        var waypoint = Waypoint()
        waypoint.id = newPacketId()
        waypoint.latitudeI = Int32(latitude * 1e7)
        waypoint.longitudeI = Int32(longitude * 1e7)
        waypoint.name = "Shared location"

        var decoded = DataMessage()
        decoded.portnum = .waypointApp
        decoded.payload = (try? waypoint.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        switch destination {
        case .channel(let index):
            packet.to = UInt32.max
            packet.channel = UInt32(index)
        case .node(let num):
            packet.to = UInt32(truncatingIfNeeded: num)
        }
        packet.decoded = decoded

        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    /// Post-onboarding: introduce ourselves to the mesh (fills the roster fast)
    /// and only now ask for notification permission — after the app proved useful.
    func finishOnboarding() {
        NotificationManager.shared.requestPermission()
        if !defaults.bool(forKey: "didFirstAnnounce") {
            defaults.set(true, forKey: "didFirstAnnounce")
            announceNodeInfo(onChannel: 0)
        }
    }

    /// A Store & Forward router has heartbeated recently — history requests can work.
    var storeForwardAvailable: Bool {
        guard sfRouterNum > 0, let heard = sfRouterHeardAt else { return false }
        return Date().timeIntervalSince(heard) < 3 * 60 * 60
    }

    /// Ask a known Store & Forward router to replay messages covering our offline
    /// window. Only when a router heartbeated recently and we were actually away.
    private func requestStoreForwardHistoryIfUseful() {
        guard storeForwardAvailable, let last = lastSyncedAt else { return }
        let awayMinutes = Int(Date().timeIntervalSince(last) / 60)
        guard awayMinutes >= 5 else { return }
        requestStoreForwardHistory(windowMinutes: min(awayMinutes + 10, 240))
    }

    /// Manual history request (the "+" menu). Replays dedupe on ingest.
    func requestStoreForwardHistory(windowMinutes: Int = 240) {
        guard storeForwardAvailable else { return }
        var sf = StoreAndForward()
        sf.rr = .clientHistory
        sf.history.window = UInt32(windowMinutes)
        var decoded = DataMessage()
        decoded.portnum = .storeForwardApp
        decoded.payload = (try? sf.serializedData()) ?? Data()
        decoded.wantResponse = true
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: sfRouterNum)
        packet.decoded = decoded
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    /// Broadcast a waypoint (shared pin) on a channel.
    func sendWaypoint(name: String, emoji: String, latitude: Double, longitude: Double,
                      expire: Date?, channel index: Int32) {
        guard let store else { return }
        var waypoint = Waypoint()
        waypoint.id = newPacketId()
        waypoint.latitudeI = Int32(latitude * 1e7)
        waypoint.longitudeI = Int32(longitude * 1e7)
        waypoint.name = String(name.prefix(29))
        if let scalar = emoji.unicodeScalars.first {
            waypoint.icon = scalar.value
        }
        if let expire {
            waypoint.expire = UInt32(expire.timeIntervalSince1970)
        }

        var decoded = DataMessage()
        decoded.portnum = .waypointApp
        decoded.payload = (try? waypoint.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32.max
        packet.channel = UInt32(index)
        packet.decoded = decoded

        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
        // Show it locally right away.
        let myNum = myNodeNum
        let wp = waypoint
        Task { await store.applyWaypoint(wp, from: myNum) }
    }

    /// Broadcast our NodeInfo on a channel right now, instead of waiting for the
    /// periodic schedule. want_response invites others to answer with theirs,
    /// so it doubles as a roster refresh.
    // MARK: - Reliability resend protocol (docs/RELIABILITY.md, port 423)

    static let reliabilityPort = 423

    /// What became of an "Ask to Resend" tap, so the gap pill can say
    /// (TODO 192): the request's routing fate, replies received, timeout.
    struct ResendRequest: Equatable {
        var sentAt: Date
        var packetId: UInt32
        var delivered = false      // their radio acked the request
        var nakError: Int32 = 0    // routing NAK; -2 = we weren't connected
        var recovered = 0          // RESEND frames received
        var tooOld = 0             // TOO_OLD frames received
        var timedOut = false
        var inFlight: Bool { !delivered && nakError == 0 && !timedOut && recovered == 0 && tooOld == 0
            || delivered && recovered == 0 && tooOld == 0 && !timedOut }
    }
    @Published private(set) var resendRequests: [String: ResendRequest] = [:]
    static func resendKey(conversationKey: String, sender: Int64) -> String { "\(conversationKey)/\(sender)" }
    private static let resendTimeout: TimeInterval = 45

    /// "Ask to resend": NACK the sender for the missing sequence numbers.
    func requestResend(from sender: Int64, conversationKey: String, seqs: [Int]) {
        guard !seqs.isEmpty else { return }
        let key = Self.resendKey(conversationKey: conversationKey, sender: sender)
        guard state == .connected else {
            resendRequests[key] = ResendRequest(sentAt: Date(), packetId: 0, nakError: -2)
            return
        }
        var frame = Data([0x01])
        if conversationKey.hasPrefix("ch-"), let index = UInt8(conversationKey.dropFirst(3)) {
            frame.append(contentsOf: [1, index])
        } else {
            frame.append(contentsOf: [0, 0])
        }
        let batch = seqs.prefix(8)
        frame.append(UInt8(batch.count))
        frame.append(contentsOf: batch.map { UInt8($0 & 0xFF) })
        let packetId = sendReliability(to: sender, payload: frame)
        resendRequests[key] = ResendRequest(sentAt: Date(), packetId: packetId)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resendTimeout))
            guard let self, var request = self.resendRequests[key], request.packetId == packetId,
                  request.recovered == 0, request.tooOld == 0 else { return }
            request.timedOut = true
            self.resendRequests[key] = request
        }
    }

    /// Reply frames from `from` count toward whatever we asked that node.
    private func noteResendReply(from: Int64, bytes: [UInt8], tooOld: Bool) {
        guard bytes.count >= 3 else { return }
        let convoKey = bytes[1] == 0 ? ConversationEntity.dmKey(from) : ConversationEntity.channelKey(Int32(bytes[2]))
        let key = Self.resendKey(conversationKey: convoKey, sender: from)
        guard var request = resendRequests[key] else { return }
        if tooOld { request.tooOld += 1 } else { request.recovered += 1 }
        resendRequests[key] = request
    }

    private static func describeReliability(_ bytes: [UInt8]) -> String {
        guard let type = bytes.first else { return "empty" }
        switch type {
        case 0x01: return "NACK \(bytes.count > 3 ? Int(bytes[3]) : 0) seq(s)"
        case 0x02: return "RESEND seq \(bytes.count > 3 ? Int(bytes[3]) : -1)"
        case 0x03: return "TOO_OLD seq \(bytes.count > 3 ? Int(bytes[3]) : -1)"
        default: return "type \(type)"
        }
    }

    private func handleReliabilityFrame(from: Int64, payload: Data) {
        guard let store, let first = payload.first else { return }
        let bytes = [UInt8](payload)
        let myNum = myNodeNum
        switch first {
        case 0x01:   // NACK: we are the original sender — answer with RESENDs
            Task {
                let frames = await store.handleResendRequest(from: from, bytes: bytes)
                await MainActor.run {
                    for frame in frames { self.sendReliability(to: from, payload: frame) }
                }
            }
        case 0x02:   // RESEND: recovered message
            noteResendReply(from: from, bytes: bytes, tooOld: false)
            Task { await store.ingestResend(from: from, bytes: bytes, myNum: myNum) }
        case 0x03:   // TOO_OLD
            noteResendReply(from: from, bytes: bytes, tooOld: true)
            Task { await store.markGapUnrecoverable(from: from, bytes: bytes) }
        default:
            break
        }
    }

    @discardableResult
    private func sendReliability(to num: Int64, payload: Data) -> UInt32 {
        var decoded = DataMessage()
        decoded.portnum = PortNum.UNRECOGNIZED(Self.reliabilityPort)
        decoded.payload = payload
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: num)
        packet.wantAck = true
        packet.decoded = decoded
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
        logTraffic(from: myNodeNum, port: "sent",
                   summary: "→ resend \(String(format: "!%08x", UInt32(truncatingIfNeeded: num))) #\(String(format: "%08X", packet.id)): \(Self.describeReliability([UInt8](payload)))")
        return packet.id
    }

    // MARK: - Presence probes (round-trip liveness)

    enum PresenceState: Equatable {
        case checking(Date)
        case reachable(Date)
        case noResponse(Date)
    }
    /// Per-peer round-trip reachability, driven by probes and resolved by ANY
    /// packet from the peer. Only peers that were probed are tracked.
    @Published private(set) var presence: [Int64: PresenceState] = [:]
    private var lastProbeAt: [Int64: Date] = [:]

    /// Forensics for the node card: when the last probe went out and what
    /// came back. respondedAt is the first packet heard from the peer after
    /// the probe — round trip in the honest, any-packet sense.
    struct ProbeRecord {
        var sentAt: Date
        var respondedAt: Date?
        var replyHops: Int?   // nil = unknown (packet carried no hop info)
    }
    @Published private(set) var lastProbe: [Int64: ProbeRecord] = [:]

    // MARK: - Traceroute (issue #1: text-only diagnostic, no map)

    struct TraceHop: Identifiable, Equatable {
        let num: Int64
        let name: String
        let snr: Float?       // dB at this hop, nil = unknown
        var id: Int64 { num }
    }
    struct TraceRouteRecord: Equatable {
        var sentAt: Date
        var packetId: UInt32
        var respondedAt: Date?
        var towards: [TraceHop] = []   // you → … → target
        var back: [TraceHop] = []      // target → … → you (empty if not reported)
        var timedOut = false
    }
    @Published private(set) var lastTraceroute: [Int64: TraceRouteRecord] = [:]
    private static let tracerouteTimeout: TimeInterval = 60

    /// Ask the firmware for the path to `num`. One in flight per peer; the
    /// reply is a RouteDiscovery on the same port with our packet id as
    /// request_id. Rendered as a list in the node card — never on the map.
    func traceRoute(to num: Int64) {
        guard state == .connected, num > 0, num != myNodeNum else { return }
        if let inFlight = lastTraceroute[num], inFlight.respondedAt == nil, !inFlight.timedOut,
           Date().timeIntervalSince(inFlight.sentAt) < Self.tracerouteTimeout { return }
        var decoded = DataMessage()
        decoded.portnum = .tracerouteApp
        decoded.payload = (try? RouteDiscovery().serializedData()) ?? Data()
        decoded.wantResponse = true
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: num)
        packet.wantAck = true
        packet.decoded = decoded
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
        lastTraceroute[num] = TraceRouteRecord(sentAt: Date(), packetId: packet.id)
        logTraffic(from: myNodeNum, port: "sent",
                   summary: "→ traceroute \(String(format: "!%08x", UInt32(truncatingIfNeeded: num))) #\(String(format: "%08X", packet.id))")
        let id = packet.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.tracerouteTimeout))
            guard let self, var record = self.lastTraceroute[num],
                  record.packetId == id, record.respondedAt == nil else { return }
            record.timedOut = true
            self.lastTraceroute[num] = record
        }
    }

    private func handleTracerouteReply(_ packet: MeshPacket, from fromNum: Int64) {
        guard let store,
              let route = try? RouteDiscovery(serializedBytes: packet.decoded.payload) else { return }
        let requestId = packet.decoded.requestID
        guard requestId != 0,
              let (target, record) = lastTraceroute.first(where: { $0.value.packetId == requestId }) else { return }
        let myNum = myNodeNum
        // Firmware convention: route = intermediate nodes; snr arrays have one
        // entry per hop including the final one, scaled ×4, INT8_MIN = unknown.
        func hops(_ nums: [UInt32], _ snrs: [Int32], start: Int64, end: Int64) -> [(Int64, Float?)] {
            let chain = [start] + nums.map { Int64($0) } + [end]
            return chain.enumerated().map { i, n in
                let snr: Float? = i == 0 ? nil : (i - 1 < snrs.count && snrs[i - 1] != -128 ? Float(snrs[i - 1]) / 4 : nil)
                return (n, snr)
            }
        }
        let towardsRaw = hops(route.route, route.snrTowards, start: myNum, end: target)
        let backRaw = route.routeBack.isEmpty && route.snrBack.isEmpty
            ? [] : hops(route.routeBack, route.snrBack, start: target, end: myNum)
        Task {
            func named(_ raw: [(Int64, Float?)]) async -> [TraceHop] {
                var out: [TraceHop] = []
                for (n, snr) in raw {
                    let name: String
                    if n == myNum { name = "You" }
                    else if let snap = await store.nodeSnapshot(num: n), !snap.shortName.isEmpty { name = snap.shortName }
                    else { name = String(format: "!%08x", UInt32(truncatingIfNeeded: n)) }
                    out.append(TraceHop(num: n, name: name, snr: snr))
                }
                return out
            }
            let towards = await named(towardsRaw)
            let back = await named(backRaw)
            await MainActor.run {
                var updated = record
                updated.respondedAt = Date()
                updated.towards = towards
                updated.back = back
                self.lastTraceroute[target] = updated
                let path = towards.map { hop -> String in
                    if let s = hop.snr { return "\(hop.name) (\(String(format: "%.1f", s)) dB)" }
                    return hop.name
                }.joined(separator: " → ")
                self.logTraffic(from: fromNum, port: "traceroute", summary: "route: \(path)")
            }
        }
    }

    /// Unicast NodeInfo with want_response — the peer's FIRMWARE answers, no
    /// app required on their end. Proves the round trip that predicts whether
    /// a message would ack. Rate-limited: probes are cheap for us, congestion
    /// for the mesh.
    func probePresence(_ num: Int64, force: Bool = false) {
        guard state == .connected, num > 0, num != myNodeNum else { return }
        if !force {
            if case .reachable(let at)? = presence[num],
               Date().timeIntervalSince(at) < 120 { return }
            if let last = lastProbeAt[num], Date().timeIntervalSince(last) < 900 { return }   // 15 min max
        }
        if case .checking = presence[num] { return }   // one in flight at a time
        lastProbeAt[num] = Date()
        lastProbe[num] = ProbeRecord(sentAt: Date())
        presence[num] = .checking(Date())
        sendTargetedNodeInfo(to: num)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, case .checking = self.presence[num] else { return }
            self.presence[num] = .noResponse(Date())
        }
    }

    /// Any packet from a tracked peer proves the round trip.
    private func notePresenceHeard(_ num: Int64, hops: Int) {
        guard presence[num] != nil else { return }
        presence[num] = .reachable(Date())
        if var record = lastProbe[num], record.respondedAt == nil {
            record.respondedAt = Date()
            record.replyHops = hops >= 0 ? hops : nil
            lastProbe[num] = record
        }
    }

    private func sendTargetedNodeInfo(to num: Int64) {
        guard let store, myNodeNum > 0 else { return }
        let myNum = myNodeNum
        Task {
            guard let snapshot = await store.nodeSnapshot(num: myNum) else { return }
            await MainActor.run {
                var user = User()
                user.id = String(format: "!%08x", UInt32(truncatingIfNeeded: myNum))
                user.longName = snapshot.longName
                user.shortName = snapshot.shortName
                if !snapshot.publicKey.isEmpty { user.publicKey = snapshot.publicKey }
                var decoded = DataMessage()
                decoded.portnum = .nodeinfoApp
                decoded.payload = (try? user.serializedData()) ?? Data()
                decoded.wantResponse = true   // unicast: asks THEIR radio to reply
                var packet = MeshPacket()
                packet.id = self.newPacketId()
                packet.from = UInt32(truncatingIfNeeded: myNum)
                packet.to = UInt32(truncatingIfNeeded: num)
                packet.decoded = decoded
                var toRadio = ToRadio()
                toRadio.packet = packet
                self.write(toRadio)
            }
        }
    }

    /// Presence announce: peers holding "send when their radio is heard"
    /// messages for us release them on hearing ANY packet from us — so on
    /// app-open and on connect, broadcast a nodeinfo. Rate-limited to be a
    /// polite mesh citizen (LoRa airtime is shared).
    private static let presenceAnnounceInterval: TimeInterval = 30 * 60
    func announcePresenceIfDue() {
        guard state == .connected, myNodeNum > 0 else { return }
        let last = UserDefaults.standard.double(forKey: "lastPresenceAnnounceAt")
        guard Date().timeIntervalSince1970 - last >= Self.presenceAnnounceInterval else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastPresenceAnnounceAt")
        announceNodeInfo(onChannel: 0)
    }

    /// Delete a still-queued (never transmitted) message.
    func deleteQueued(packetId: Int64) {
        guard let store else { return }
        Task { await store.deleteQueuedMessage(packetId: packetId) }
    }

    func announceNodeInfo(onChannel index: Int32, noteInTranscript: Bool = false) {
        guard let store, myNodeNum > 0 else { return }
        let myNum = myNodeNum
        Task {
            guard let snapshot = await store.nodeSnapshot(num: myNum) else { return }
            let sentPacketId: Int64 = await MainActor.run {
                var user = User()
                user.id = String(format: "!%08x", UInt32(truncatingIfNeeded: myNum))
                user.longName = snapshot.longName
                user.shortName = snapshot.shortName
                if !snapshot.publicKey.isEmpty { user.publicKey = snapshot.publicKey }

                var decoded = DataMessage()
                decoded.portnum = .nodeinfoApp
                decoded.payload = (try? user.serializedData()) ?? Data()
                // No wantResponse: on a broadcast it asks every receiver to
                // answer with their own info — noise, not an exchange.

                var packet = MeshPacket()
                packet.id = self.newPacketId()
                packet.from = UInt32(truncatingIfNeeded: myNum)
                packet.to = UInt32.max
                packet.channel = UInt32(index)
                // Same flags as channel texts: wantAck earns the implicit-ack
                // routing result. Without it nothing ever came back, and the
                // 5-min stale sweep failed EVERY node-info note.
                packet.wantAck = true
                packet.decoded = decoded

                var toRadio = ToRadio()
                toRadio.packet = packet
                self.write(toRadio)
                return Int64(packet.id)
            }
            if noteInTranscript {
                // Gray transcript note that rides the real packet id, so the
                // ack/sweep machinery reports whether it actually went out.
                await store.persistSystemNote(packetId: sentPacketId, channelIndex: index,
                                              myNum: myNum, text: "You shared your node info")
            }
        }
    }

    // MARK: - Admin (the only radio-config writes in Hops)

    /// Sets the radio's owner names. Names are clamped to the firmware's
    /// byte limits (see `MeshName`) — an overflowing name is silently
    /// dropped by the radio, which is what "I can't change my name" looked
    /// like (TODO 177). The local node record is updated optimistically and
    /// reverted if the radio NAKs the admin packet.
    func setOwner(longName: String, shortName: String) {
        let long = MeshName.clampLong(longName.trimmingCharacters(in: .whitespaces))
        let short = MeshName.clampShort(shortName.trimmingCharacters(in: .whitespaces))
        // Only against the radio that answered MyInfo this session — a
        // persisted myNodeNum from an earlier radio would rename the wrong
        // record (issue #2).
        guard !long.isEmpty, !short.isEmpty, myNodeNum > 0, state == .connected, let store else { return }
        var user = User()
        user.longName = long
        user.shortName = short
        var admin = AdminMessage()
        admin.setOwner = user
        let packetId = sendAdmin(admin)
        Task {
            let previous = await store.nodeSnapshot(num: myNodeNum)
            pendingOwner = PendingOwner(packetId: packetId,
                                        previousLong: previous?.longName ?? "",
                                        previousShort: previous?.shortName ?? "")
            await store.renameNode(num: myNodeNum, longName: long, shortName: short)
        }
    }

    /// A radio without GPS boots with its clock at the firmware build date
    /// and drifts from there, and every packet's rx_time comes from that
    /// clock. Set it from the phone on each connect, as the official app
    /// does (TODO 179). The firmware keeps a better source (GPS) if it has one.
    private func setRadioTime(via link: RadioLink) {
        var admin = AdminMessage()
        admin.setTimeOnly = UInt32(clamping: Int(Date().timeIntervalSince1970))
        var decoded = DataMessage()
        decoded.portnum = .adminApp
        decoded.payload = (try? admin.serializedData()) ?? Data()
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: link.nodeNum)
        packet.to = UInt32(truncatingIfNeeded: link.nodeNum)
        packet.decoded = decoded
        packet.wantAck = true
        packet.priority = .reliable
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio, via: link)
        logTraffic(from: link.nodeNum, port: "sent",
                   summary: "→ admin #\(String(format: "%08X", packet.id)): set time")
    }

    func applyLoRaConfig(regionRaw: Int, presetRaw: Int, frequencySlot: Int, hopLimit: Int,
                         metroPresetId: String? = nil) {
        MetroPresetStore.shared.appliedPresetId = metroPresetId
        var lora = Config.LoRaConfig()
        lora.usePreset = true
        lora.region = Config.LoRaConfig.RegionCode(rawValue: regionRaw) ?? .us
        lora.modemPreset = Config.LoRaConfig.ModemPreset(rawValue: presetRaw) ?? .longFast
        lora.channelNum = UInt32(frequencySlot)
        lora.hopLimit = UInt32(hopLimit)
        lora.txEnabled = true
        var config = Config()
        config.lora = lora
        var admin = AdminMessage()
        admin.setConfig = config
        sendAdmin(admin)
        // Optimistic local mirror; the radio reboots after a LoRa write and the
        // re-sync will confirm.
        loRa = LoRaSnapshot(received: true, regionRaw: regionRaw, presetRaw: presetRaw,
                            frequencySlot: frequencySlot, hopLimit: hopLimit)
        persistLoRa()
        needsMeshSetup = false
    }

    func applyChannelSet(_ channelSet: ChannelSet) {
        for (position, settings) in channelSet.settings.enumerated() {
            var channel = Channel()
            channel.index = Int32(position)
            channel.role = position == 0 ? .primary : .secondary
            channel.settings = settings
            var admin = AdminMessage()
            admin.setChannel = channel
            sendAdmin(admin)
        }
        if channelSet.hasLoraConfig {
            let lora = channelSet.loraConfig
            applyLoRaConfig(regionRaw: lora.region == .unset ? loRa.regionRaw : lora.region.rawValue,
                            presetRaw: lora.modemPreset.rawValue,
                            frequencySlot: Int(lora.channelNum),
                            hopLimit: lora.hopLimit > 0 ? Int(lora.hopLimit) : loRa.hopLimit)
        }
    }

    /// Write one device-config section (bluetooth / display / position / …).
    func applyConfig(_ config: Config) {
        var admin = AdminMessage()
        admin.setConfig = config
        sendAdmin(admin)
    }

    func applyModuleConfig(_ moduleConfig: ModuleConfig) {
        var admin = AdminMessage()
        admin.setModuleConfig = moduleConfig
        sendAdmin(admin)
        // Module-config writes don't reboot the radio, so no re-sync happens.
        // Mirror optimistically, then read back to confirm what actually stuck.
        if case .telemetry(let telemetry) = moduleConfig.payloadVariant {
            telemetryConfig = telemetry
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.requestModuleConfig(.telemetryConfig)
            }
        }
    }

    /// Ask the radio for a module config section; the answer arrives as an
    /// adminApp packet handled in handleMeshPacket.
    /// Multi-config saves must be transactional: each setConfig schedules a
    /// firmware save+reboot, and writes racing that reboot are silently lost.
    /// begin defers the reboot; commit applies everything at once.
    func beginEditSettings() {
        var admin = AdminMessage()
        admin.beginEditSettings = true
        sendAdmin(admin)
    }

    func commitEditSettings() {
        var admin = AdminMessage()
        admin.commitEditSettings = true
        sendAdmin(admin)
    }

    func requestConfig(_ type: AdminMessage.ConfigType) {
        var admin = AdminMessage()
        admin.getConfigRequest = type
        var decoded = DataMessage()
        decoded.portnum = .adminApp
        decoded.payload = (try? admin.serializedData()) ?? Data()
        decoded.wantResponse = true
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: myNodeNum)
        packet.priority = .reliable
        packet.decoded = decoded
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    func requestModuleConfig(_ type: AdminMessage.ModuleConfigType) {
        var admin = AdminMessage()
        admin.getModuleConfigRequest = type
        var decoded = DataMessage()
        decoded.portnum = .adminApp
        decoded.payload = (try? admin.serializedData()) ?? Data()
        decoded.wantResponse = true
        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: myNodeNum)
        packet.priority = .reliable
        packet.decoded = decoded
        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    func setChannel(index: Int32, name: String, roleRaw: Int32, psk: Data) {
        var settings = ChannelSettings()
        settings.name = String(name.prefix(11))
        settings.psk = psk
        var channel = Channel()
        channel.index = index
        channel.role = Channel.Role(rawValue: Int(roleRaw)) ?? .secondary
        channel.settings = settings
        var admin = AdminMessage()
        admin.setChannel = channel
        sendAdmin(admin)
        Task { await store?.applyChannel(channel) }
    }

    /// Returns the packet id so callers can correlate the routing result.
    @discardableResult
    private func sendAdmin(_ admin: AdminMessage) -> UInt32 {
        sendAdmin(admin, via: nil)
    }

    @discardableResult
    private func sendAdmin(_ admin: AdminMessage, via link: RadioLink?) -> UInt32 {
        let target = link?.nodeNum ?? myNodeNum
        var decoded = DataMessage()
        decoded.portnum = .adminApp
        decoded.payload = (try? admin.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: target)
        packet.to = UInt32(truncatingIfNeeded: target)
        packet.decoded = decoded
        packet.wantAck = true
        packet.priority = .reliable

        var toRadio = ToRadio()
        toRadio.packet = packet
        if let link { write(toRadio, via: link) } else { write(toRadio) }
        logTraffic(from: target, port: "sent",
                   summary: "→ admin #\(String(format: "%08X", packet.id)): \(adminLabel(admin))")
        return packet.id
    }

    private func adminLabel(_ admin: AdminMessage) -> String {
        switch admin.payloadVariant {
        case .setOwner: return "set owner"
        case .setTimeOnly: return "set time"
        case .setConfig: return "set config"
        case .setChannel(let ch): return "set channel \(ch.index)"
        case .setModuleConfig: return "set module config"
        case .addContact(let c): return "add contact \(c.user.id)"
        case .setFavoriteNode(let n): return "favorite \(String(format: "!%08x", n))"
        default: return String(describing: admin.payloadVariant).components(separatedBy: "(").first ?? "admin"
        }
    }

    private func persistLoRa() {
        defaults.set(true, forKey: Keys.loraReceived)
        defaults.set(loRa.regionRaw, forKey: Keys.region)
        defaults.set(loRa.presetRaw, forKey: Keys.preset)
        defaults.set(loRa.frequencySlot, forKey: Keys.slot)
        defaults.set(loRa.hopLimit, forKey: Keys.hopLimit)
    }

    /// Writes to the transmit radio. Handshake traffic names its link.
    private func write(_ toRadio: ToRadio) {
        guard let link = transmitLink
                ?? links.values.first(where: { $0.phase == .connected })
                ?? links.values.first(where: { $0.phase == .syncing }) else { return }
        write(toRadio, via: link)
    }

    private func write(_ toRadio: ToRadio, via link: RadioLink) {
        guard let data = try? toRadio.serializedData() else { return }
        central.write(id: link.id, data)
    }

    // MARK: - On-demand refresh (Settings pull-to-refresh)

    /// Ask the radio for fresh status: a direct telemetry request for current
    /// battery/metrics, plus a node-DB re-request so everything else updates too.
    func refreshDeviceStatus() async {
        guard state == .connected else {
            connectIfNeeded()
            try? await Task.sleep(for: .seconds(1))
            return
        }
        var heartbeat = ToRadio()
        heartbeat.heartbeat = Heartbeat()
        write(heartbeat)
        requestOwnTelemetry()
        for link in links.values where link.phase == .connected {
            link.nodeDBRequested = false
            requestNodeDBIfNeeded(link)
        }
        // Give the radio a beat to answer so the refresh spinner reflects reality.
        try? await Task.sleep(for: .seconds(1.5))
    }

    private func requestOwnTelemetry() {
        var telemetry = Telemetry()
        telemetry.deviceMetrics = DeviceMetrics()

        var decoded = DataMessage()
        decoded.portnum = .telemetryApp
        decoded.payload = (try? telemetry.serializedData()) ?? Data()
        decoded.wantResponse = true

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: myNodeNum)
        packet.decoded = decoded

        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    // MARK: - App lifecycle hooks

    func appDidBecomeActive() {
        connectIfNeeded()
        announcePresenceIfDue()
        if LocationProvider.shared.isAuthorized {
            Task { _ = await LocationProvider.shared.current() }
        }
        guard let store else { return }
        let attachedNow = Set(attachedNodeNums)
        Task {
            let reholds = await store.sweepStaleSending(attachedRadios: attachedNow)
            for packetId in reholds {
                await store.prepareRetryHold(packetId: packetId,
                                             newPacketId: Int64(self.newPacketId()))
            }
            let unread = await store.totalUnreadConversations()
            await NotificationManager.shared.setBadge(unread)
        }
    }

    /// Time-boxed background sync for BGAppRefreshTask: connect, config, drain — never
    /// the node DB. Returns when synced or when the box expires.
    func backgroundSync(timeout: TimeInterval = 20) async {
        connectIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .connected { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if state == .connected {
            try? await Task.sleep(for: .seconds(3))  // let the drain settle
        }
    }
}

/// One radio the phone holds (or is arming a connect for): its Bluetooth
/// identity plus everything a session learns from that radio alone.
@MainActor
final class RadioLink {
    enum Phase: Equatable {
        case armed        // pending connect; radio out of range
        case connecting
        case syncing      // link up, config drain in flight
        case connected
        case bondLost
    }
    let id: UUID
    var nodeNum: Int64 = 0
    var phase: Phase = .armed
    var firmwareVersion = ""
    var loRa = RadioManager.LoRaSnapshot()
    var bluetoothConfig: Config.BluetoothConfig?
    var deviceConfig: Config.DeviceConfig?
    var displayConfig: Config.DisplayConfig?
    var positionConfig: Config.PositionConfig?
    var telemetryConfig: ModuleConfig.TelemetryConfig?
    var connectedAt: Date?
    var lastSyncedAt: Date?
    var trustedRxWindow: ClosedRange<Date>?
    var knownPeers: Set<Int64> = []
    var preloadedThisSession: Set<Int64> = []
    var nodeDBRequested = false
    var watchdog: Task<Void, Never>?
    /// This radio's own channel table, from its config dump.
    var channels: [Int32: MessageStore.ChannelSnapshot] = [:]
    /// How this radio differs from the fleet (channels + LoRa); empty = in step.
    var drift: [String] = []

    init(id: UUID) { self.id = id }
}

/// Tracks foreground/background so notification suppression works without views.
@MainActor
final class UIStateObserver {
    static let shared = UIStateObserver()
    var isActive = false {
        didSet { if isActive, !oldValue { Task { @MainActor in TrafficMonitor.shared.publishIfDirty() } } }
    }
}

/// Everything that changes on every heard packet — the traffic log and its
/// counters — kept off RadioManager so one packet doesn't re-render every
/// view observing the radio (TODO 188: Settings re-fetched all nodes per
/// render and, in the background, spun until iOS killed the app for CPU).
/// Publishes only while the app is active; in the background it accumulates
/// and publishes once on return.
@MainActor
final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()

    private(set) var entries: [RadioManager.TrafficEntry] = []
    private(set) var meshPacketsHeard = 0
    private(set) var textMessagesHeard = 0
    private(set) var lastMeshPacketAt: Date?
    private var counter = 0
    private var dirty = false

    private func willChange() {
        if UIStateObserver.shared.isActive { objectWillChange.send() } else { dirty = true }
    }

    func publishIfDirty() {
        guard dirty else { return }
        dirty = false
        objectWillChange.send()
    }

    func noteMeshPacket() {
        willChange()
        meshPacketsHeard += 1
        lastMeshPacketAt = Date()
    }

    func noteTextMessage() {
        willChange()
        textMessagesHeard += 1
    }

    func append(from: Int64, port: String, summary: String, snr: Float, hopsAway: Int) {
        willChange()
        counter += 1
        entries.insert(RadioManager.TrafficEntry(id: counter, date: Date(), fromNum: from,
                                                 portName: port, summary: summary,
                                                 snr: snr, hopsAway: hopsAway), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }
}

private extension UserDefaults {
    func boolWithDefault(_ key: String, _ fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
}
