import Foundation
import Combine
import CoreBluetooth
import SwiftData
import OSLog
import MeshtasticProtobufs

@MainActor
final class RadioManager: ObservableObject {

    static let shared = RadioManager()

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
    @Published private(set) var discovered: [BLETransport.Discovered] = []
    @Published private(set) var lastSyncedAt: Date?
    @Published var needsMeshSetup = false     // factory-fresh radio: region unset

    // Mesh-traffic diagnostics (since launch): distinguishes "radio hears nothing"
    // (config/frequency problem) from "app mishandles what arrives" (our bug).
    @Published private(set) var meshPacketsHeard = 0
    @Published private(set) var textMessagesHeard = 0
    @Published private(set) var lastMeshPacketAt: Date?

    // Device configs mirrored from the connect-time dump; nil until received.
    @Published var bluetoothConfig: Config.BluetoothConfig?
    @Published var displayConfig: Config.DisplayConfig?
    @Published var positionConfig: Config.PositionConfig?

    struct TrafficEntry: Identifiable {
        let id: Int
        let date: Date
        let fromNum: Int64
        let portName: String
        let summary: String
    }
    /// Rolling log of decoded mesh traffic, newest first (capped).
    @Published private(set) var trafficLog: [TrafficEntry] = []
    private var trafficCounter = 0

    private func logTraffic(from: Int64, port: String, summary: String) {
        trafficCounter += 1
        trafficLog.insert(TrafficEntry(id: trafficCounter, date: Date(), fromNum: from,
                                       portName: port, summary: summary), at: 0)
        if trafficLog.count > 200 {
            trafficLog.removeLast(trafficLog.count - 200)
        }
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
    private let transport = BLETransport()
    private var store: MessageStore?
    private var bluetoothOn = false
    private var pairingInProgress = false
    private var nodeDBRequested = false

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let peripheralId = "pairedPeripheralId"
        static let myNodeNum = "myNodeNum"
        static let lastSynced = "lastSyncedAt"
        static let firmware = "firmwareVersion"
        static let region = "loraRegion"
        static let preset = "loraPreset"
        static let slot = "loraSlot"
        static let hopLimit = "loraHopLimit"
        static let loraReceived = "loraReceived"
    }

    var pairedPeripheralId: UUID? {
        get { defaults.string(forKey: Keys.peripheralId).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Keys.peripheralId) }
    }

    /// The key of the conversation currently on screen; its messages don't notify.
    var activeConversationKey: String?

    private init() {
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
        state = pairedPeripheralId == nil ? .noRadio : .offline
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    func configure(container: ModelContainer) {
        let store = MessageStore(modelContainer: container)
        self.store = store
        Task { await store.repairConversations() }
    }

    // MARK: - Pairing

    func beginPairingScan() {
        discovered = []
        pairingInProgress = true
        transport.startScan()
    }

    func endPairingScan() {
        pairingInProgress = false
        transport.stopScan()
    }

    func pair(with id: UUID) {
        pairedPeripheralId = id
        pairingInProgress = false
        state = .connecting
        transport.connectDiscovered(id: id)
    }

    func forgetRadio() {
        transport.disconnect(userInitiated: true)
        pairedPeripheralId = nil
        myNodeNum = 0
        defaults.set(0, forKey: Keys.myNodeNum)
        defaults.set(false, forKey: Keys.loraReceived)
        loRa = LoRaSnapshot()
        state = .noRadio
    }

    // MARK: - Connection lifecycle

    /// User chose to disconnect (without forgetting the radio); persists so a
    /// relaunch doesn't silently reconnect against their wishes.
    @Published var userDisconnected: Bool = UserDefaults.standard.bool(forKey: "userDisconnected") {
        didSet { UserDefaults.standard.set(userDisconnected, forKey: "userDisconnected") }
    }

    func disconnectByUser() {
        userDisconnected = true
        transport.disconnect(userInitiated: true)
        state = .offline
    }

    func reconnectByUser() {
        userDisconnected = false
        connectIfNeeded()
    }

    func connectIfNeeded() {
        guard let id = pairedPeripheralId, bluetoothOn, !userDisconnected else { return }
        guard state == .offline || state == .bondLost else { return }
        state = .connecting
        transport.connect(to: id)
    }

    private func handle(_ event: BLETransport.Event) {
        switch event {
        case .bluetoothState(let cbState):
            bluetoothOn = cbState == .poweredOn
            if !bluetoothOn {
                if pairedPeripheralId != nil { state = .bluetoothOff }
            } else {
                if state == .bluetoothOff { state = .offline }
                if pairingInProgress { transport.startScan() }
                connectIfNeeded()
            }

        case .discovered(let device):
            guard pairingInProgress else { return }
            if let index = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[index].rssi = device.rssi
            } else {
                discovered.append(device)
            }
            discovered.sort { $0.rssi > $1.rssi }

        case .linkReady:
            state = .syncing
            nodeDBRequested = false
            startHandshake()

        case .disconnected(let userInitiated):
            let hadSession = state == .connected || state == .syncing
            state = pairedPeripheralId == nil ? .noRadio : .offline
            // Re-arm the pending connect on every non-user disconnect path — this is
            // what lets iOS relaunch us when the radio comes back in range.
            if !userInitiated, let id = pairedPeripheralId, bluetoothOn {
                if hadSession { state = .connecting }
                transport.connect(to: id)
                if hadSession { state = .offline }
            }

        case .bondLost:
            state = .bondLost
            NotificationManager.shared.postBondLost()

        case .frame(let data):
            process(frame: data)

        case .drainComplete:
            if state == .connected {
                touchLastSynced()
            }
        }
    }

    // MARK: - Handshake (messages first, node DB deferred)

    private func startHandshake() {
        var heartbeat = ToRadio()
        heartbeat.heartbeat = Heartbeat()
        write(heartbeat)

        var wantConfig = ToRadio()
        wantConfig.wantConfigID = 69420   // NONCE_ONLY_CONFIG
        write(wantConfig)
        transport.drain()
    }

    private func handleConfigComplete(_ nonce: UInt32) {
        switch nonce {
        case 69420:
            state = .connected
            touchLastSynced()
            needsMeshSetup = loRa.received && loRa.regionRaw == Config.LoRaConfig.RegionCode.unset.rawValue
            flushOutboxAndSweep()
            // Node DB is deliberately deferred: on a big mesh it can take minutes and
            // messages must never wait behind it.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.requestNodeDBIfNeeded()
            }
        case 69421:
            touchLastSynced()
        default:
            break
        }
    }

    private func requestNodeDBIfNeeded() {
        guard state == .connected, !nodeDBRequested else { return }
        nodeDBRequested = true
        var toRadio = ToRadio()
        toRadio.wantConfigID = 69421      // NONCE_ONLY_DB
        write(toRadio)
        transport.drain()
    }

    private func flushOutboxAndSweep() {
        guard let store else { return }
        Task {
            let queued = await store.drainOutbox()
            for record in queued {
                await MainActor.run { self.transmit(record) }
            }
            await store.sweepStaleSending()
        }
    }

    private func touchLastSynced() {
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Keys.lastSynced)
    }

    // MARK: - Inbound frames

    private func process(frame: Data) {
        guard let fromRadio = try? FromRadio(serializedBytes: frame) else {
            log.error("undecodable FromRadio frame (\(frame.count) bytes)")
            return
        }
        switch fromRadio.payloadVariant {
        case .myInfo(let myInfo):
            myNodeNum = Int64(myInfo.myNodeNum)
            defaults.set(myNodeNum, forKey: Keys.myNodeNum)

        case .metadata(let metadata):
            firmwareVersion = metadata.firmwareVersion
            defaults.set(firmwareVersion, forKey: Keys.firmware)

        case .config(let config):
            switch config.payloadVariant {
            case .bluetooth(let bluetooth): bluetoothConfig = bluetooth
            case .display(let display): displayConfig = display
            case .position(let position): positionConfig = position
            default: break
            }
            if case .lora(let lora) = config.payloadVariant {
                loRa = LoRaSnapshot(received: true,
                                    regionRaw: lora.region.rawValue,
                                    presetRaw: lora.modemPreset.rawValue,
                                    frequencySlot: Int(lora.channelNum),
                                    hopLimit: Int(lora.hopLimit))
                persistLoRa()
                // If the radio's config matches a known metro preset but we never
                // recorded applying it (applied before tracking existed, or via
                // another app), adopt it — this drives the channel icon.
                MetroPresetStore.shared.inferAppliedPreset(regionRaw: loRa.regionRaw,
                                                           presetRaw: loRa.presetRaw,
                                                           frequencySlot: loRa.frequencySlot)
            }

        case .channel(let channel):
            Task { await store?.applyChannel(channel) }

        case .nodeInfo(let nodeInfo):
            Task { await store?.applyNodeInfo(nodeInfo) }

        case .configCompleteID(let nonce):
            handleConfigComplete(nonce)

        case .rebooted:
            // Radio rebooted mid-session (e.g. after a config write): full re-sync.
            startHandshake()

        case .packet(let packet):
            handleMeshPacket(packet)

        default:
            break
        }
    }

    private func handleMeshPacket(_ packet: MeshPacket) {
        guard let store else { return }
        let fromNum = Int64(packet.from)
        if fromNum != myNodeNum {
            meshPacketsHeard += 1
            lastMeshPacketAt = Date()
            Task {
                await store.heard(num: fromNum, snr: packet.rxSnr,
                                  hopStart: packet.hopStart, hopLimit: packet.hopLimit,
                                  rxTime: packet.rxTime)
            }
        }
        guard case .decoded(let decoded) = packet.payloadVariant else {
            logTraffic(from: fromNum, port: "encrypted", summary: "Undecodable (no matching channel key)")
            return
        }
        if decoded.portnum == .textMessageApp, fromNum != myNodeNum {
            textMessagesHeard += 1
        }
        logTraffic(from: fromNum, port: portLabel(decoded.portnum), summary: trafficSummary(decoded))

        switch decoded.portnum {
        case .textMessageApp, .detectionSensorApp, .alertApp:
            let myNum = myNodeNum
            Task {
                if let inbound = await store.ingestTextMessage(packet: packet, myNum: myNum) {
                    await MainActor.run { self.notifyIfAppropriate(inbound) }
                }
                let unread = await store.totalUnreadConversations()
                await NotificationManager.shared.setBadge(unread)
            }

        case .routingApp:
            guard decoded.requestID != 0, let routing = try? Routing(serializedBytes: decoded.payload) else { return }
            let errorRaw = Int32(routing.errorReason.rawValue)
            Task {
                await store.applyRoutingResult(requestId: decoded.requestID,
                                               errorRaw: errorRaw,
                                               ackFrom: Int64(packet.from),
                                               ackTo: Int64(packet.to))
            }

        case .positionApp:
            guard let position = try? Position(serializedBytes: decoded.payload) else { return }
            Task { await store.applyPositionPacket(position, from: fromNum) }

        case .nodeinfoApp:
            guard let user = try? User(serializedBytes: decoded.payload) else { return }
            var info = NodeInfo()
            info.num = packet.from
            info.user = user
            Task { await store.applyNodeInfo(info) }

        case .telemetryApp:
            guard let telemetry = try? Telemetry(serializedBytes: decoded.payload) else { return }
            Task { await store.applyTelemetry(telemetry, from: fromNum) }

        case .waypointApp:
            guard let waypoint = try? Waypoint(serializedBytes: decoded.payload) else { return }
            Task { await store.applyWaypoint(waypoint, from: fromNum) }

        default:
            break
        }
    }

    private func portLabel(_ port: PortNum) -> String {
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
        if !prefs.boolWithDefault("notificationsEnabled", true) { return }
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
                  isEmoji: Bool = false, replyId: Int64 = 0) {
        guard let store else { return }
        let packetId = newPacketId()
        let connected = state == .connected || state == .syncing
        let myNum = myNodeNum
        Task {
            let record = await store.persistOutgoing(packetId: Int64(packetId), myNum: myNum,
                                                     destination: destination, text: text,
                                                     isEmoji: isEmoji, replyId: replyId,
                                                     connected: connected)
            if connected {
                await MainActor.run { self.transmit(record) }
            }
        }
    }

    func retry(packetId: Int64) {
        guard let store else { return }
        let newId = newPacketId()
        let connected = state == .connected
        Task {
            if let record = await store.prepareRetry(packetId: packetId, newPacketId: Int64(newId), connected: connected) {
                await MainActor.run { self.transmit(record) }
            }
        }
    }

    private func transmit(_ record: MessageStore.OutgoingRecord) {
        var decoded = DataMessage()
        decoded.portnum = .textMessageApp
        decoded.payload = record.text.data(using: .utf8) ?? Data()
        if record.isEmoji {
            decoded.emoji = 1
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
    }

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

    // MARK: - Admin (the only radio-config writes in Hops)

    func setOwner(longName: String, shortName: String) {
        var user = User()
        user.longName = String(longName.prefix(36))
        user.shortName = String(shortName.prefix(4))
        var admin = AdminMessage()
        admin.setOwner = user
        sendAdmin(admin)
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

    private func sendAdmin(_ admin: AdminMessage) {
        var decoded = DataMessage()
        decoded.portnum = .adminApp
        decoded.payload = (try? admin.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = newPacketId()
        packet.from = UInt32(truncatingIfNeeded: myNodeNum)
        packet.to = UInt32(truncatingIfNeeded: myNodeNum)
        packet.decoded = decoded
        packet.wantAck = true

        var toRadio = ToRadio()
        toRadio.packet = packet
        write(toRadio)
    }

    private func persistLoRa() {
        defaults.set(true, forKey: Keys.loraReceived)
        defaults.set(loRa.regionRaw, forKey: Keys.region)
        defaults.set(loRa.presetRaw, forKey: Keys.preset)
        defaults.set(loRa.frequencySlot, forKey: Keys.slot)
        defaults.set(loRa.hopLimit, forKey: Keys.hopLimit)
    }

    private func write(_ toRadio: ToRadio) {
        guard let data = try? toRadio.serializedData() else { return }
        transport.write(data)
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
        nodeDBRequested = false
        requestNodeDBIfNeeded()
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
        guard let store else { return }
        Task {
            await store.sweepStaleSending()
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

/// Tracks foreground/background so notification suppression works without views.
@MainActor
final class UIStateObserver {
    static let shared = UIStateObserver()
    var isActive = false
}

private extension UserDefaults {
    func boolWithDefault(_ key: String, _ fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
}
