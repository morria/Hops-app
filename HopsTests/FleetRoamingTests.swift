import XCTest
import SwiftData
import MeshtasticProtobufs
@testable import Hops

/// Two radios, one phone: attach both, the priority order picks the sender,
/// dropping the top one fails over (docs/MULTI_RADIO.md §1.2–1.3).
@MainActor
final class FleetRoamingTests: XCTestCase {
    var mock: MockTransport!
    var radio: RadioManager!
    var container: ModelContainer!
    let a = UUID(), b = UUID()
    let numA: Int64 = 0x1000_0001, numB: Int64 = 0x1000_0002

    override func setUp() async throws {
        mock = MockTransport()
        let suite = UserDefaults(suiteName: "fleet-tests-\(UUID().uuidString)")!
        radio = RadioManager(transport: mock, defaults: suite)
        let schema = Schema([ConversationEntity.self, MessageEntity.self, NodeEntity.self,
                             ChannelEntity.self, WaypointEntity.self, PositionSampleEntity.self,
                             CoverageSampleEntity.self, SeqTrackEntity.self, RadioEntity.self,
                             GameSessionEntity.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        radio.configure(container: container)
        try await settle()
    }

    private func settle(_ seconds: Double = 0.3) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func frame(_ build: (inout FromRadio) -> Void) -> Data {
        var fr = FromRadio()
        build(&fr)
        return try! fr.serializedData()
    }

    /// Pair `id` and run the whole handshake as the radio would.
    private func attach(_ id: UUID, nodeNum: Int64) async throws {
        radio.beginPairingScan()
        mock.emit(.bluetoothState(.poweredOn))
        mock.emit(.discovered(.init(id: id, name: "Meshtastic", rssi: -50)))
        radio.pair(with: id)
        mock.emit(.linkReady(id))
        mock.emit(.frame(id, frame { $0.myInfo.myNodeNum = UInt32(nodeNum) }))
        mock.emit(.frame(id, frame { $0.metadata.firmwareVersion = "2.7.26" }))
        mock.emit(.frame(id, frame { $0.configCompleteID = 69420 }))
        try await settle()
    }

    func testFirstRadioBecomesTransmit() async throws {
        try await attach(a, nodeNum: numA)
        XCTAssertEqual(radio.state, .connected)
        XCTAssertEqual(radio.myNodeNum, numA)
        XCTAssertEqual(radio.attached.count, 1)
        XCTAssertTrue(radio.attached[0].isTransmit)
        XCTAssertEqual(radio.fleet.map(\.nodeNum), [numA])
        XCTAssertTrue(radio.isMine(numA))
        // Handshake went to that link: heartbeat + want_config.
        let packets = mock.packets(to: a)
        XCTAssertTrue(packets.contains { $0.wantConfigID == 69420 })
    }

    func testSecondRadioAttachesAndPriorityPicksSender() async throws {
        try await attach(a, nodeNum: numA)
        try await attach(b, nodeNum: numB)
        XCTAssertEqual(radio.attached.count, 2)
        XCTAssertEqual(radio.myNodeNum, numA, "first added has priority 0")
        XCTAssertTrue(radio.isMine(numB))

        radio.reorderFleet([numB, numA])
        try await settle()
        XCTAssertEqual(radio.fleet.map(\.nodeNum), [numB, numA])
        XCTAssertEqual(radio.myNodeNum, numB, "the top attached radio sends")
        XCTAssertTrue(radio.attached.first { $0.nodeNum == numB }!.isTransmit)
    }

    func testDroppingTransmitRadioFailsOverAndReArms() async throws {
        try await attach(a, nodeNum: numA)
        try await attach(b, nodeNum: numB)
        mock.emit(.disconnected(a, wasUserInitiated: false))
        try await settle(0.1)
        XCTAssertEqual(radio.myNodeNum, numB)
        XCTAssertEqual(radio.state, .connected)
        XCTAssertTrue(mock.wanted.contains(a), "the dropped radio keeps a pending connect")
        XCTAssertEqual(radio.attached.filter { $0.phase == .connected }.count, 1)
    }

    func testSendsGoThroughTransmitRadioOnly() async throws {
        try await attach(a, nodeNum: numA)
        try await attach(b, nodeNum: numB)
        radio.reorderFleet([numB, numA])
        try await settle()
        let before = mock.writes.count
        radio.sendText("hello", to: .channel(0))
        try await settle(0.5)
        let newWrites = mock.writes.suffix(from: before)
        let texts = newWrites.compactMap { w -> (UUID, MeshPacket)? in
            guard let tr = try? ToRadio(serializedBytes: w.data), case .packet(let p) = tr.payloadVariant,
                  p.decoded.portnum == .textMessageApp else { return nil }
            return (w.id, p)
        }
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first?.0, b, "text left through the priority radio")
        XCTAssertEqual(texts.first?.1.from, UInt32(numB))
    }

    // MARK: - Renumbering (TODO 223)

    private func ownNodeInfo(_ nodeNum: Int64, mac: Data) -> Data {
        frame {
            $0.nodeInfo.num = UInt32(nodeNum)
            $0.nodeInfo.user.longName = "Base"
            $0.nodeInfo.user.shortName = "BASE"
            $0.nodeInfo.user.macaddr = mac
            $0.nodeInfo.user.hwModel = .tbeam
        }
    }

    private func nodeInfoBroadcasts(to id: UUID) -> [User] {
        mock.packets(to: id).compactMap { tr -> User? in
            guard case .packet(let p) = tr.payloadVariant, p.decoded.portnum == .nodeinfoApp,
                  p.to == UInt32.max else { return nil }
            return try? User(serializedBytes: p.decoded.payload)
        }
    }

    func testRenumberedRadioKeepsItsRow() async throws {
        try await attach(a, nodeNum: numA)
        try await attach(b, nodeNum: numB)
        radio.renameRadio(numB, nickname: "Attic")
        radio.setRadioLocation(numB, tag: "home")
        try await settle()

        // The same peripheral comes back from a reboot with a new number.
        let renumbered: Int64 = 0x2BAD_CAFE
        mock.emit(.frame(b, frame { $0.myInfo.myNodeNum = UInt32(renumbered) }))
        try await settle()

        XCTAssertEqual(radio.fleet.map(\.nodeNum), [numA, renumbered], "one row per physical radio")
        XCTAssertEqual(radio.fleet.last?.nickname, "Attic")
        XCTAssertEqual(radio.fleet.last?.locationTag, "home")
        XCTAssertFalse(radio.isMine(numB))
        XCTAssertTrue(radio.isMine(renumbered))
        XCTAssertFalse(mock.forgotten.contains(b), "the Bluetooth link is untouched")
    }

    func testAnnounceCarriesTheRadiosHardwareAddress() async throws {
        try await attach(a, nodeNum: numA)
        let mac = Data([0xAA, 0xBB, 0x10, 0x00, 0x00, 0x01])
        mock.emit(.frame(a, ownNodeInfo(numA, mac: mac)))
        try await settle()
        radio.announceNodeInfo(onChannel: 0)
        try await settle()
        let sent = nodeInfoBroadcasts(to: a)
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0.macaddr == mac }, "a NodeInfo without macaddr makes the firmware renumber")
        XCTAssertTrue(sent.allSatisfy { $0.hwModel == .tbeam }, "the radio's own record is the base")
    }

    func testNoAnnounceWithoutAHardwareAddress() async throws {
        try await attach(a, nodeNum: numA)
        mock.emit(.frame(a, ownNodeInfo(numA, mac: Data())))
        try await settle()
        radio.announceNodeInfo(onChannel: 0)
        try await settle()
        XCTAssertTrue(nodeInfoBroadcasts(to: a).isEmpty)
    }

    func testForgetRemovesFromFleetAndTransport() async throws {
        try await attach(a, nodeNum: numA)
        try await attach(b, nodeNum: numB)
        radio.forget(radio: numB)
        try await settle()
        XCTAssertEqual(radio.fleet.map(\.nodeNum), [numA])
        XCTAssertTrue(mock.forgotten.contains(b))
        XCTAssertFalse(radio.isMine(numB))
    }
}
