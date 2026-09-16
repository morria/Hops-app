import Foundation
import SwiftData
import CoreBluetooth
import OSLog
import MeshtasticProtobufs

/// The watch's own link to one Meshtastic radio. Pairs by scanning, runs the
/// config handshake, feeds text packets into the shared store, and sends
/// what the user types. Deliberately small: no fleet, no admin, no
/// Meshsites, no games. A radio holds ONE Bluetooth connection, so the
/// watch only gets it while the phone isn't attached.
@MainActor
final class WatchRadio: NSObject, ObservableObject {
    static let shared = WatchRadio()

    enum State: Equatable { case noRadio, bluetoothOff, offline, connecting, syncing, connected }

    @Published private(set) var state: State = .noRadio
    @Published private(set) var myNodeNum: Int64 = 0
    @Published private(set) var discovered: [BLECentral.Discovered] = []
    @Published private(set) var scanning = false
    @Published private(set) var radioName: String = ""

    private let log = Logger(subsystem: "com.w2asm.hops.watch", category: "radio")
    private let central = BLECentral()
    private var store: MessageStore?
    private var peripheralId: UUID? {
        didSet { UserDefaults.standard.set(peripheralId?.uuidString, forKey: "watchPeripheralId") }
    }
    private var bluetoothOn = false
    private var lastSyncedAt: Date? {
        get { UserDefaults.standard.object(forKey: "watchLastSyncedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "watchLastSyncedAt") }
    }
    private var trustedRxWindow: ClosedRange<Date>?

    private override init() {
        super.init()
        if let s = UserDefaults.standard.string(forKey: "watchPeripheralId") { peripheralId = UUID(uuidString: s) }
        radioName = UserDefaults.standard.string(forKey: "watchRadioName") ?? ""
        central.onEvent = { [weak self] event in self?.handle(event) }
    }

    func configure(container: ModelContainer) {
        store = MessageStore(modelContainer: container)
        central.activate()
        connectIfNeeded()
    }

    var hasRadio: Bool { peripheralId != nil }

    // MARK: - Pairing

    func startScan() {
        discovered = []
        scanning = true
        central.activate()
        central.startScan()
    }

    func stopScan() {
        scanning = false
        central.stopScan()
    }

    func pair(with device: BLECentral.Discovered) {
        stopScan()
        if let old = peripheralId, old != device.id { central.forget(old) }
        peripheralId = device.id
        radioName = device.name
        UserDefaults.standard.set(device.name, forKey: "watchRadioName")
        state = .connecting
        central.connectDiscovered(id: device.id)
    }

    func forget() {
        if let id = peripheralId { central.forget(id) }
        peripheralId = nil
        radioName = ""
        myNodeNum = 0
        state = .noRadio
    }

    func connectIfNeeded() {
        guard let id = peripheralId, bluetoothOn else { return }
        if state == .noRadio || state == .offline { state = .connecting }
        central.connect(to: [id])
    }

    // MARK: - Events

    private func handle(_ event: BLECentral.Event) {
        switch event {
        case .bluetoothState(let s):
            bluetoothOn = s == .poweredOn
            if !bluetoothOn { state = peripheralId == nil ? .noRadio : .bluetoothOff; return }
            if scanning { central.startScan() }
            connectIfNeeded()
        case .discovered(let device):
            guard scanning else { return }
            if let i = discovered.firstIndex(where: { $0.id == device.id }) { discovered[i].rssi = device.rssi }
            else { discovered.append(device) }
        case .linkReady(let id):
            guard id == peripheralId else { return }
            state = .syncing
            var heartbeat = ToRadio(); heartbeat.heartbeat = Heartbeat()
            write(heartbeat)
            var wantConfig = ToRadio(); wantConfig.wantConfigID = 69420
            write(wantConfig)
            central.drain(id: id)
        case .frame(let id, let data):
            guard id == peripheralId, let frame = try? FromRadio(serializedBytes: data) else { return }
            process(frame)
        case .disconnected(let id, _):
            guard id == peripheralId else { return }
            state = bluetoothOn ? .offline : .bluetoothOff
            if bluetoothOn { central.connect(to: [id]) }   // pending connect: back when in range
        default:
            break
        }
    }

    private func process(_ frame: FromRadio) {
        guard let store else { return }
        switch frame.payloadVariant {
        case .myInfo(let info):
            myNodeNum = Int64(info.myNodeNum)
            let num = myNodeNum
            Task { await store.setLocalNodeNums([num]) }
        case .channel(let channel):
            Task { await store.applyChannel(channel) }
        case .nodeInfo(let info):
            Task { await store.applyNodeInfo(info) }
        case .configCompleteID(let nonce) where nonce == 69420:
            let now = Date()
            if let previous = lastSyncedAt, previous <= now { trustedRxWindow = previous...now } else { trustedRxWindow = nil }
            lastSyncedAt = now
            state = .connected
            flushOutbox()
        case .packet(let packet):
            handle(packet)
        default:
            break
        }
    }

    private func handle(_ packet: MeshPacket) {
        guard let store, case .decoded(let decoded) = packet.payloadVariant else { return }
        let from = Int64(packet.from)
        Task {
            await store.heard(num: from, snr: packet.rxSnr, hopStart: packet.hopStart,
                              hopLimit: packet.hopLimit, rxTime: packet.rxTime)
        }
        switch decoded.portnum {
        case .textMessageApp:
            let myNum = myNodeNum, window = trustedRxWindow
            Task { _ = await store.ingestTextMessage(packet: packet, myNum: myNum, trustedRxWindow: window, viaNodeNum: myNum) }
        case .routingApp:
            guard decoded.requestID != 0, Int64(packet.to) == myNodeNum,
                  let routing = try? Routing(serializedBytes: decoded.payload) else { return }
            let error = Int32(routing.errorReason.rawValue)
            Task {
                _ = await store.applyRoutingResult(requestId: decoded.requestID, errorRaw: error,
                                                   ackFrom: from, ackTo: Int64(packet.to))
            }
        case .nodeinfoApp:
            if let user = try? User(serializedBytes: decoded.payload) {
                var info = NodeInfo(); info.num = packet.from; info.user = user
                Task { await store.applyNodeInfo(info) }
            }
        default:
            break
        }
    }

    // MARK: - Sending

    func sendText(_ text: String, to destination: MessageDestinationRef) {
        guard let store else { return }
        let packetId = UInt32.random(in: 0x100..<UInt32.max)
        let connected = state == .connected
        let myNum = myNodeNum
        Task {
            let record = await store.persistOutgoing(packetId: Int64(packetId), myNum: myNum,
                                                     destination: destination, text: text,
                                                     isEmoji: false, replyId: 0, connected: connected)
            if connected { await MainActor.run { self.transmit(record) } }
        }
    }

    private func flushOutbox() {
        guard let store else { return }
        Task {
            let records = await store.drainOutbox()
            await MainActor.run { for r in records { self.transmit(r) } }
        }
    }

    private func transmit(_ record: MessageStore.OutgoingRecord) {
        var decoded = DataMessage()
        decoded.portnum = .textMessageApp
        decoded.payload = record.text.data(using: .utf8) ?? Data()
        if record.seqNum >= 0 {
            decoded.bitfield = (decoded.bitfield & 0x03) | 0x80 | (UInt32(record.seqNum & 0x1F) << 2)
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

    private func write(_ toRadio: ToRadio) {
        guard let id = peripheralId, let data = try? toRadio.serializedData() else { return }
        central.write(id: id, data)
    }

    func markRead(_ key: String) {
        Task { await store?.markConversationRead(key: key) }
    }
}
