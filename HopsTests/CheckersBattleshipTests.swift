import XCTest
@testable import Hops

final class CheckersBattleshipTests: XCTestCase {

    // MARK: - Checkers

    /// Empty board with the given (square, content) pairs.
    private func board(_ pieces: [Int: UInt8]) -> [UInt8] {
        var s = [UInt8](repeating: Checkers.empty, count: 32)
        for (sq, v) in pieces { s[sq] = v }
        return s
    }

    func testCheckersInitialPositionHasSevenMoves() {
        let g = Checkers(options: Data())
        XCTAssertEqual(g.toMove, .one)
        XCTAssertNil(g.result)
        let moves = g.legalMoves()
        XCTAssertEqual(moves.count, 7)
        XCTAssertTrue(moves.contains(Data([20, 16])))
        XCTAssertTrue(moves.contains(Data([23, 19])))
        XCTAssertFalse(moves.contains(Data([20, 17])), "not diagonal")
        XCTAssertEqual(g.describe(Data([23, 19])), "24–20")
    }

    func testCheckersCaptureIsMandatoryFromScriptedOpening() throws {
        var g = Checkers(options: Data())
        try g.apply(Data([23, 19]))   // one: (5,6) → (4,7)
        try g.apply(Data([10, 15]))   // two: (2,5) → (3,6), offering a piece
        // one's man on 19 must jump over 15 into the vacated 10; nothing else is legal.
        XCTAssertEqual(g.legalMoves(), [Data([19, 10])])
        XCTAssertEqual(g.describe(Data([19, 10])), "20×11")
        XCTAssertThrowsError(try g.apply(Data([20, 16]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        try g.apply(Data([19, 10]))
        XCTAssertEqual(g.squares[15], Checkers.empty, "captured piece removed")
        XCTAssertEqual(g.squares[10], Checkers.oneMan)
        XCTAssertEqual(g.toMove, .two, "no further jump, so the turn passes")
        // two must recapture: from 6 over 10 to 15, or from 7 over 10 to 14.
        XCTAssertEqual(Set(g.legalMoves()), [Data([6, 15]), Data([7, 14])])
    }

    func testCheckersMultiJumpKeepsTurnAndRestrictsMoves() throws {
        // one man on 20 (5,0); two men on 16 (4,1) and 8 (2,1); landing squares 13 (3,2) and 4 (1,0) empty.
        // A second one man on 28 and a two man on 0 keep both sides alive.
        var g = Checkers(squares: board([20: Checkers.oneMan, 28: Checkers.oneMan,
                                         16: Checkers.twoMan, 8: Checkers.twoMan, 0: Checkers.twoMan]),
                         toMove: .one)
        XCTAssertEqual(g.legalMoves(), [Data([20, 13])])
        try g.apply(Data([20, 13]))
        XCTAssertEqual(g.toMove, .one, "still jumping")
        XCTAssertEqual(g.jumping, 13)
        XCTAssertEqual(g.legalMoves(), [Data([13, 4])], "only the continuation jump is legal")
        XCTAssertThrowsError(try g.apply(Data([28, 24]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        try g.apply(Data([13, 4]))
        XCTAssertEqual(g.toMove, .two)
        XCTAssertNil(g.jumping)
        XCTAssertEqual(g.squares[16], Checkers.empty)
        XCTAssertEqual(g.squares[8], Checkers.empty)
        XCTAssertNil(g.result)
        XCTAssertEqual(g.canonical[33], 255, "no mid-jump square in the canonical state")
    }

    func testCheckersPromotionCrownsAndEndsSequence() throws {
        // one man on 8 (2,1) jumps two's man on 5 (1,2) landing on 1 (0,3), the king row.
        // Two's man on 6 (1,4) would be jumpable by a king from 1, but promotion ends the turn.
        var g = Checkers(squares: board([8: Checkers.oneMan, 5: Checkers.twoMan, 6: Checkers.twoMan]), toMove: .one)
        XCTAssertEqual(g.legalMoves(), [Data([8, 1])])
        try g.apply(Data([8, 1]))
        XCTAssertEqual(g.squares[1], Checkers.oneKing)
        XCTAssertEqual(g.toMove, .two)
        XCTAssertNil(g.jumping)
        // A piece on the edge row can't be jumped, so two's man on 6 steps; the new king then moves down the board.
        try g.apply(Data([6, 10]))
        XCTAssertTrue(g.legalMoves().contains(Data([1, 5])), "king moves down the board")
    }

    func testCheckersNoMovesIsALossAndGameOverThrows() throws {
        var g = Checkers(squares: board([20: Checkers.oneMan, 16: Checkers.twoMan]), toMove: .one)
        try g.apply(Data([20, 13]))   // captures two's last piece
        XCTAssertEqual(g.result, .win(.one))
        XCTAssertThrowsError(try g.apply(Data([13, 9]))) { XCTAssertEqual($0 as? GameError, .gameOver) }
        // Blocked pieces count as no moves too.
        let blocked = Checkers(squares: board([28: Checkers.oneMan, 24: Checkers.twoMan, 21: Checkers.twoMan]), toMove: .one)
        XCTAssertEqual(blocked.result, .win(.two))
    }

    func testCheckersFortyQuietKingMovesIsADraw() throws {
        var g = Checkers(squares: board([28: Checkers.oneKing, 0: Checkers.twoKing]), toMove: .one, quietKingMoves: 39)
        XCTAssertNil(g.result)
        try g.apply(Data([28, 24]))
        XCTAssertEqual(g.result, .draw)
    }

    func testCheckersMalformedMoveThrows() {
        var g = Checkers(options: Data())
        XCTAssertThrowsError(try g.apply(Data([20]))) { XCTAssertEqual($0 as? GameError, .malformedMove) }
        XCTAssertThrowsError(try g.apply(Data([8, 12]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
    }

    func testCheckersReplayReproducesCanonical() throws {
        let script: [UInt8] = [23, 19, 10, 15, 19, 10, 6, 15]
        var g = Checkers(options: Data())
        for i in stride(from: 0, to: script.count, by: 2) { try g.apply(Data(script[i..<(i + 2)])) }
        let replayed = try GameKind.checkers.replay(options: Data([0]), moves: Data(script))
        XCTAssertEqual(replayed.canonical, g.canonical)
        XCTAssertEqual(g.canonical.count, 35)
        XCTAssertEqual(g.canonical[32], Player.one.rawValue)
        XCTAssertEqual(StateHash.of(replayed), StateHash.of(g))
    }

    // MARK: - Battleship

    /// Player two's fleet: horizontal, rows 0–4 from column 0.
    private let fleetTwo = Data([0, 0, 0,  1, 0, 0,  2, 0, 0,  3, 0, 0,  4, 0, 0])
    /// Player one's fleet: vertical, columns 9,8,7,6,5 from row 0.
    private let fleetOne = Data([0, 9, 1,  0, 8, 1,  0, 7, 1,  0, 6, 1,  0, 5, 1])

    func testBattleshipPlacementValidation() {
        for _ in 0..<50 { XCTAssertTrue(Battleship.placementIsValid(Battleship.randomPlacement())) }
        XCTAssertTrue(Battleship.placementIsValid(fleetOne))
        XCTAssertTrue(Battleship.placementIsValid(fleetTwo))
        XCTAssertFalse(Battleship.placementIsValid(Data()))
        XCTAssertFalse(Battleship.placementIsValid(Data([0, 6, 0,  1, 0, 0,  2, 0, 0,  3, 0, 0,  4, 0, 0])), "carrier runs off the right edge")
        XCTAssertFalse(Battleship.placementIsValid(Data([0, 0, 0,  0, 0, 0,  2, 0, 0,  3, 0, 0,  4, 0, 0])), "overlap")
        XCTAssertFalse(Battleship.placementIsValid(Data([0, 0, 2,  1, 0, 0,  2, 0, 0,  3, 0, 0,  4, 0, 0])), "bad orientation")
        XCTAssertEqual(Battleship.shipCells(fleetTwo)?[4], [40, 41])
    }

    func testBattleshipFullGameSinksFleet() throws {
        var g = Battleship(options: Data())
        XCTAssertEqual(g.toMove, .one)
        XCTAssertFalse(g.isReportPending)
        let targets: [UInt8] = [0, 1, 2, 3, 4,  10, 11, 12, 13,  20, 21, 22,  30, 31, 32,  40, 41]
        let decoys: [UInt8] = Array(90...99) + Array(80...85)   // all water for player one
        let sinkOn: [Int: UInt8] = [4: 0x90, 8: 0x91, 11: 0x92, 14: 0x93, 16: 0x94]
        for (i, target) in targets.enumerated() {
            try g.apply(Data([target]))
            XCTAssertEqual(g.toMove, .two)
            XCTAssertTrue(g.isReportPending)
            XCTAssertEqual(g.pendingShot, Int(target))
            XCTAssertNil(g.autoMove(privateData: Data()), "no placement, no report")
            let report = g.autoMove(privateData: fleetTwo)!
            XCTAssertEqual(report, Data([sinkOn[i] ?? 0x81]))
            try g.apply(report)
            XCTAssertEqual(g.toMove, .two, "defender shoots next")
            XCTAssertFalse(g.isReportPending)
            XCTAssertEqual(g.hits(by: .one), i + 1)
            if g.result != nil { break }
            try g.apply(Data([decoys[i]]))
            XCTAssertEqual(g.toMove, .one)
            let reply = g.autoMove(privateData: fleetOne)!
            XCTAssertEqual(reply, Data([0x80]))
            try g.apply(reply)
            XCTAssertEqual(g.toMove, .one)
        }
        XCTAssertEqual(g.result, .win(.one))
        XCTAssertEqual(g.sunkShips(by: .one), [0, 1, 2, 3, 4])
        XCTAssertEqual(g.hits(by: .two), 0)
        XCTAssertEqual(g.shots(by: .two).count, 16)
        XCTAssertTrue(g.legalMoves().isEmpty)
        XCTAssertThrowsError(try g.apply(Data([50]))) { XCTAssertEqual($0 as? GameError, .gameOver) }
        // The log replays to the same public state.
        let replayed = try GameKind.battleship.replay(options: Data([0]), moves: Data(g.log))
        XCTAssertEqual(replayed.canonical, g.canonical)
        XCTAssertEqual(replayed.result, .win(.one))
    }

    func testBattleshipAutoMoveReportsMissHitAndSunk() throws {
        var g = Battleship(options: Data())
        XCTAssertNil(g.autoMove(privateData: fleetTwo), "not a report turn")
        try g.apply(Data([55]))
        XCTAssertEqual(g.autoMove(privateData: fleetTwo), Data([0x80]))
        try g.apply(Data([0x80]))
        try g.apply(Data([99]))
        try g.apply(g.autoMove(privateData: fleetOne)!)
        try g.apply(Data([41]))                                  // destroyer, first half
        XCTAssertEqual(g.autoMove(privateData: fleetTwo), Data([0x81]))
        try g.apply(Data([0x81]))
        try g.apply(Data([98]))
        try g.apply(Data([0x80]))
        try g.apply(Data([40]))                                  // destroyer, second half
        XCTAssertEqual(g.autoMove(privateData: fleetTwo), Data([0x94]))
        XCTAssertEqual(g.describe(Data([0x94])), "sunk the Destroyer")
        try g.apply(Data([0x94]))
        XCTAssertEqual(g.sunkShips(by: .one), [4])
        XCTAssertEqual(g.hits(by: .one), 2)
        XCTAssertFalse(g.legalMoves().contains(Data([0x94])) , "a sunk ship can't sink twice")
    }

    func testBattleshipIllegalMoves() throws {
        var g = Battleship(options: Data())
        XCTAssertThrowsError(try g.apply(Data([0x80]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }   // nothing to report
        XCTAssertThrowsError(try g.apply(Data([1, 2]))) { XCTAssertEqual($0 as? GameError, .malformedMove) }
        XCTAssertThrowsError(try g.apply(Data([100]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        try g.apply(Data([7]))
        XCTAssertThrowsError(try g.apply(Data([8]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }      // must report first
        XCTAssertThrowsError(try g.apply(Data([0x95]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }   // no sixth ship
        try g.apply(Data([0x80]))
        try g.apply(Data([7]))    // two may shoot the same cell on one's board
        try g.apply(Data([0x80]))
        XCTAssertThrowsError(try g.apply(Data([7]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }      // one already shot 7
        XCTAssertEqual(g.legalMoves().count, 99)
    }

    func testBattleshipDescribeAndCanonical() throws {
        var g = Battleship(options: Data())
        XCTAssertEqual(g.describe(Data([0])), "A1")
        XCTAssertEqual(g.describe(Data([16])), "B7")
        XCTAssertEqual(g.describe(Data([99])), "J10")
        XCTAssertEqual(g.describe(Data([0x80])), "miss")
        XCTAssertEqual(g.describe(Data([0x81])), "hit")
        XCTAssertEqual(g.describe(Data([0x92])), "sunk the Cruiser")
        XCTAssertEqual(g.canonical, Data([0]))
        try g.apply(Data([16]))
        XCTAssertEqual(g.canonical, Data([16, 1]))
        try g.apply(Data([0x81]))
        XCTAssertEqual(g.canonical, Data([16, 0x81, 1]))
        let replayed = try GameKind.battleship.replay(options: Data(), moves: Data([16, 0x81]))
        XCTAssertEqual(replayed.canonical, g.canonical)
    }
}
