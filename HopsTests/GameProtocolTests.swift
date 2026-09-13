import XCTest
@testable import Hops

/// Two endpoints, a lossy channel in between: every move counts only once
/// both sides hold the same state (docs/GAMES.md §2).
final class GameProtocolTests: XCTestCase {

    /// A phone: its record plus the frames it wants to send.
    struct Endpoint {
        var record: GameSessionRecord
        var outbox: [GameFrame] = []
        var events: [GameEvent] = []

        mutating func receive(_ frame: GameFrame) {
            let out = GameLogic.handle(frame, record: &record)
            outbox += out.replies
            events += out.events
        }
        mutating func play(_ move: UInt8) {
            guard let f = GameLogic.play(Data([move]), in: &record) else { XCTFail("move \(move) not playable"); return }
            outbox.append(f)
        }
        mutating func resend() { outbox += GameLogic.resendFrames(record) }
    }

    func pair(kind: GameKind = .ticTacToe) -> (Endpoint, Endpoint) {
        let options = Data([0])   // inviter plays .one
        var a = Endpoint(record: GameSessionRecord(id: 0xABCD_0001, kind: kind, peer: 2, me: .one,
                                                   options: options, phase: .inviting))
        a.outbox = [GameLogic.inviteFrame(a.record)]
        let invite = a.outbox.removeFirst()
        var b = Endpoint(record: GameLogic.newInvitedRecord(from: 1, frame: invite)!)
        XCTAssertEqual(b.record.phase, .invited)
        XCTAssertEqual(b.record.me, .two)
        b.outbox.append(GameLogic.accept(&b.record)!)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.phase, .myTurn)
        XCTAssertEqual(b.record.phase, .theirTurn)
        return (a, b)
    }

    /// Delivers every queued frame, in order, no loss.
    func deliverAll(from x: inout Endpoint, to y: inout Endpoint) {
        let frames = x.outbox; x.outbox = []
        for f in frames { y.receive(f) }
    }

    func testFramesRoundTrip() {
        let frames: [GameFrame] = [
            .invite(session: 1, kind: .chess, options: Data([1, 2, 3])),
            .accept(session: 2), .decline(session: 3),
            .move(session: 4, seq: 300, prevHash: 0xDEAD_BEEF, move: Data([9, 8, 7])),
            .ack(session: 5, seq: 1, stateHash: 42),
            .nak(session: 6, seq: 2, reason: .illegalMove),
            .resync(session: 7, fromSeq: 9),
            .sync(session: 8, fromSeq: 1, moves: Data([1, 2, 3, 4])),
            .end(session: 9, reason: .drawOffer),
        ]
        for f in frames { XCTAssertEqual(GameFrame(f.encoded()), f) }
        XCTAssertNil(GameFrame(Data([0x42])))
        XCTAssertNil(GameFrame(Data([0x04, 0, 0, 0, 1])))
    }

    func testMoveCountsOnlyAfterAgreement() {
        var (a, b) = pair()
        a.play(4)
        XCTAssertEqual(a.record.phase, .waiting)
        XCTAssertEqual(a.record.seq, 0, "not committed until acked")
        deliverAll(from: &a, to: &b)
        XCTAssertEqual(b.record.seq, 1)
        XCTAssertEqual(b.record.phase, .myTurn)
        XCTAssertTrue(b.events.contains(.yourTurn))
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 1)
        XCTAssertEqual(a.record.phase, .theirTurn)
        XCTAssertEqual(a.record.currentHash, b.record.currentHash)
    }

    func testLostAckIsRecoveredByResend() {
        var (a, b) = pair()
        a.play(4)
        deliverAll(from: &a, to: &b)
        b.outbox.removeAll()          // ACK lost
        XCTAssertEqual(a.record.phase, .waiting)
        a.resend()                    // same MOVE bytes again
        XCTAssertEqual(a.outbox.count, 1)
        deliverAll(from: &a, to: &b)  // duplicate: re-acked, not re-applied
        XCTAssertEqual(b.record.seq, 1)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 1)
        XCTAssertEqual(a.record.phase, .theirTurn)
    }

    func testTheirNextMoveImpliesOurAck() {
        var (a, b) = pair()
        a.play(4)
        deliverAll(from: &a, to: &b)
        b.outbox.removeAll()          // ACK lost
        b.play(0)                     // they move anyway
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 2, "our pending move committed, theirs applied")
        XCTAssertEqual(a.record.phase, .myTurn)
        deliverAll(from: &a, to: &b)
        XCTAssertEqual(b.record.phase, .theirTurn)
        XCTAssertEqual(a.record.currentHash, b.record.currentHash)
    }

    func testDuplicateMoveIsIdempotent() {
        var (a, b) = pair()
        a.play(4)
        let move = a.outbox[0]
        deliverAll(from: &a, to: &b)
        b.receive(move); b.receive(move)
        XCTAssertEqual(b.record.seq, 1)
        XCTAssertEqual(b.outbox.count, 3, "each duplicate re-acked")
        XCTAssertTrue(b.outbox.allSatisfy { if case .ack(_, 1, _) = $0 { return true }; return false })
    }

    func testIllegalMoveIsNaked() {
        var (a, b) = pair()
        a.play(4)
        deliverAll(from: &a, to: &b)
        deliverAll(from: &b, to: &a)
        XCTAssertNil(GameLogic.play(Data([4]), in: &b.record), "occupied — refused locally")
        XCTAssertEqual(b.record.phase, .myTurn)
        // Forge it on the wire.
        b.record.pending = Data([4]); b.record.phase = .waiting
        b.outbox.append(GameLogic.moveFrame(b.record)!)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 1)
        deliverAll(from: &a, to: &b)
        XCTAssertEqual(b.record.phase, .myTurn)
        XCTAssertEqual(b.record.lastNak, .illegalMove)
        XCTAssertNil(b.record.pending)
    }

    func testGapTriggersResync() {
        var (a, b) = pair()
        a.play(4); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        b.play(0); deliverAll(from: &b, to: &a); deliverAll(from: &a, to: &b)
        // A's third move never reaches B, but B's copy is now behind: simulate
        // B losing its state to seq 1 (fresh device restored from sync).
        var stale = b.record; stale.moves = Data(stale.moves.prefix(1)); stale.settleTurn()
        b.record = stale
        a.play(8)
        deliverAll(from: &a, to: &b)
        guard case .resync(_, let from)? = b.outbox.first else { return XCTFail("expected RESYNC, got \(b.outbox)") }
        XCTAssertEqual(from, 2)
        deliverAll(from: &b, to: &a)
        guard case .sync? = a.outbox.first else { return XCTFail("expected SYNC") }
        deliverAll(from: &a, to: &b)
        XCTAssertEqual(b.record.seq, 2)
        // Now the resent move lands.
        a.resend(); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 3)
        XCTAssertEqual(b.record.seq, 3)
        XCTAssertEqual(a.record.currentHash, b.record.currentHash)
    }

    func testWrongPrevHashMarksOutOfSync() {
        var (a, b) = pair()
        a.play(4); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        // Corrupt B's state at the same seq.
        b.record.moves = Data([5])
        b.play(0)
        deliverAll(from: &b, to: &a)
        XCTAssertTrue(a.record.outOfSync)
        deliverAll(from: &a, to: &b)
        XCTAssertEqual(b.record.lastNak, .wrongPrevHash)
        XCTAssertTrue(b.record.outOfSync)
    }

    func testFullGameToWin() {
        var (a, b) = pair()
        for (mover, move) in [(0, UInt8(0)), (1, 3), (0, 1), (1, 4), (0, 2)] {
            if mover == 0 { a.play(move); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a) }
            else { b.play(move); deliverAll(from: &b, to: &a); deliverAll(from: &a, to: &b) }
        }
        XCTAssertEqual(a.record.phase, .finished)
        XCTAssertEqual(b.record.phase, .finished)
        XCTAssertEqual(a.record.result, .win(.one))
        XCTAssertEqual(b.record.result, .win(.one))
        XCTAssertTrue(a.events.contains(.finished))
        XCTAssertTrue(b.events.contains(.finished))
        XCTAssertNil(GameLogic.play(Data([5]), in: &b.record))
    }

    func testResignAndDraw() {
        var (a, b) = pair()
        a.outbox.append(GameLogic.offerDraw(a.record)!)
        deliverAll(from: &a, to: &b)
        XCTAssertTrue(b.record.drawOffered)
        b.outbox.append(GameLogic.acceptDraw(&b.record)!)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.result, .draw)
        XCTAssertEqual(b.record.result, .draw)

        var (c, d) = pair()
        c.outbox.append(GameLogic.resign(&c.record)!)
        deliverAll(from: &c, to: &d)
        XCTAssertEqual(c.record.result, .win(.two))
        XCTAssertEqual(d.record.result, .win(.two))
    }

    func testDeclineAndDuplicateInvite() {
        let options = Data([1])   // inviter plays .two
        var a = Endpoint(record: GameSessionRecord(id: 7, kind: .connectFour, peer: 2, me: .two,
                                                   options: options, phase: .inviting))
        let invite = GameLogic.inviteFrame(a.record)
        var b = Endpoint(record: GameLogic.newInvitedRecord(from: 1, frame: invite)!)
        XCTAssertEqual(b.record.me, .one)
        b.outbox.append(GameLogic.decline(&b.record)!)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.phase, .declined)
        b.receive(invite)   // resent invite after decline → decline again
        XCTAssertEqual(b.outbox, [.decline(session: 7)])
    }

    func testInviterFirstMoveCountsAsAcceptance() {
        // Invitee moves first (inviter plays .two), ACCEPT lost.
        let options = Data([1])
        var a = Endpoint(record: GameSessionRecord(id: 9, kind: .ticTacToe, peer: 2, me: .two,
                                                   options: options, phase: .inviting))
        var b = Endpoint(record: GameLogic.newInvitedRecord(from: 1, frame: GameLogic.inviteFrame(a.record))!)
        _ = GameLogic.accept(&b.record)   // ACCEPT dropped on the floor
        XCTAssertEqual(b.record.phase, .myTurn)
        b.play(4)
        deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.seq, 1)
        XCTAssertEqual(a.record.phase, .myTurn)
        XCTAssertTrue(a.events.contains(.accepted))
    }

    func testSyncFramesRespectBudget() {
        var r = GameSessionRecord(id: 1, kind: .chess, peer: 2, me: .one, options: Data([0]), phase: .theirTurn)
        r.moves = Data(repeating: 0, count: 3 * 120)   // 120 chess moves, not replayed here
        let frames = GameLogic.syncFrames(r, from: 1)
        XCTAssertEqual(frames.count, 3)
        for f in frames { XCTAssertLessThanOrEqual(f.encoded().count, 190) }
    }

    func testDotsAndBoxesExtraTurnStaysWithMover() {
        var (a, b) = pair(kind: .dotsAndBoxes)
        // Box (0,0): edges h(0,0)=0, h(1,0)=4, v(0,0)=20, v(0,1)=21. A draws 0, B 4, A 20, B... let A close it.
        a.play(0); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        b.play(4); deliverAll(from: &b, to: &a); deliverAll(from: &a, to: &b)
        a.play(20); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        b.play(8); deliverAll(from: &b, to: &a); deliverAll(from: &a, to: &b)
        a.play(21); deliverAll(from: &a, to: &b); deliverAll(from: &b, to: &a)
        XCTAssertEqual(a.record.phase, .myTurn, "closing a box keeps the turn")
        XCTAssertEqual(b.record.phase, .theirTurn)
        XCTAssertEqual((a.record.engine() as! DotsAndBoxes).score(.one), 1)
    }
}
