import XCTest
import SwiftData
import MeshtasticProtobufs
@testable import Hops

/// Store-side fleet rules: radios CRUD and the local-node merge refusal
/// covering every fleet member (issue #2 / PR #3, generalised).
final class MessageStoreFleetTests: XCTestCase {
    var container: ModelContainer!
    var store: MessageStore!

    override func setUp() async throws {
        let schema = Schema([ConversationEntity.self, MessageEntity.self, NodeEntity.self,
                             ChannelEntity.self, WaypointEntity.self, PositionSampleEntity.self,
                             CoverageSampleEntity.self, SeqTrackEntity.self, RadioEntity.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        store = MessageStore(modelContainer: container)
    }

    func testRadiosKeepPriorityOrder() async {
        await store.upsertRadio(nodeNum: 1, firmware: "2.7", publicKey: nil, battery: nil)
        await store.upsertRadio(nodeNum: 2, firmware: nil, publicKey: nil, battery: 80)
        var radios = await store.radios()
        XCTAssertEqual(radios.map(\.nodeNum), [1, 2])
        XCTAssertEqual(radios[0].nickname, "My radio", "first radio gets a default nickname")
        XCTAssertEqual(radios[1].lastBattery, 80)
        await store.reorderRadios([2, 1])
        radios = await store.radios()
        XCTAssertEqual(radios.map(\.nodeNum), [2, 1])
        await store.deleteRadio(nodeNum: 2)
        radios = await store.radios()
        XCTAssertEqual(radios.map(\.nodeNum), [1])
    }

    func testMergeRefusedWhenAnyFleetRadioSharesTheKey() async {
        let key = Data(repeating: 7, count: 32)
        await store.setLocalNodeNums([100, 200])
        // A peer record and our second radio share a key (a cloned image).
        var peer = NodeInfo(); peer.num = 300; peer.user.publicKey = key; peer.user.longName = "Peer"
        var mine = NodeInfo(); mine.num = 200; mine.user.publicKey = key; mine.user.longName = "Mine"
        await store.applyNodeInfo(peer)
        await store.applyNodeInfo(mine)
        let nums = await store.allNodeNums()
        XCTAssertTrue(nums.contains(200), "our own radio's record must survive")
        XCTAssertTrue(nums.contains(300), "and the peer's must not be folded into it")
    }

    func testMergeStillFoldsPeersThatShareAKey() async {
        let key = Data(repeating: 9, count: 32)
        await store.setLocalNodeNums([100])
        var old = NodeInfo(); old.num = 301; old.user.publicKey = key; old.user.longName = "Renumbered"
        var new = NodeInfo(); new.num = 302; new.user.publicKey = key; new.user.longName = "Renumbered"
        await store.applyNodeInfo(old)
        await store.applyNodeInfo(new)
        let nums = await store.allNodeNums()
        XCTAssertFalse(nums.contains(301))
        XCTAssertTrue(nums.contains(302))
    }
}
