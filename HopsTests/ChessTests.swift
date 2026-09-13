import XCTest
@testable import Hops

final class ChessTests: XCTestCase {

    private func sq(_ name: String) -> UInt8 { UInt8(Chess.square(named: name)!) }
    private func mv(_ s: String, promo: UInt8 = 0) -> Data {
        Data([sq(String(s.prefix(2))), sq(String(s.suffix(2))), promo])
    }
    private func play(_ moves: [String], from fen: String = Chess.startFEN) throws -> Chess {
        var chess = Chess(fen: fen)!
        for m in moves { try chess.apply(mv(m)) }
        return chess
    }

    /// Leaf-node count by recursing legalMoves() + apply on copies.
    private func perft(_ chess: Chess, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        var nodes = 0
        for m in chess.legalMoves() {
            var next = chess
            try! next.apply(m)
            nodes += depth == 1 ? 1 : perft(next, depth - 1)
        }
        return nodes
    }

    func testPerftFromStart() {
        let start = Chess(options: Data([0]))
        XCTAssertEqual(perft(start, 1), 20)
        XCTAssertEqual(perft(start, 2), 400)
        XCTAssertEqual(perft(start, 3), 8902)
    }

    func testPerftKiwipete() {
        let kiwi = Chess(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")!
        XCTAssertEqual(perft(kiwi, 1), 48)
        XCTAssertEqual(perft(kiwi, 2), 2039)
    }

    func testFoolsMate() throws {
        let chess = try play(["f2f3", "e7e5", "g2g4", "d8h4"])
        XCTAssertEqual(chess.result, .win(.two))
        XCTAssertTrue(chess.isInCheck)
        XCTAssertEqual(chess.legalMoves(), [])
        XCTAssertThrowsError(try play(["f2f3", "e7e5", "g2g4", "d8h4", "e1f2"])) {
            XCTAssertEqual($0 as? GameError, .gameOver)
        }
    }

    func testDescribeShortAlgebraic() throws {
        let start = Chess(options: Data())
        XCTAssertEqual(start.describe(mv("g1f3")), "Nf3")
        XCTAssertEqual(start.describe(mv("e2e4")), "e4")
        let before = try play(["f2f3", "e7e5", "g2g4"])
        XCTAssertEqual(before.describe(mv("d8h4")), "Qh4#")
        let castle = Chess(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        XCTAssertEqual(castle.describe(mv("e1g1")), "O-O")
        XCTAssertEqual(castle.describe(mv("e1c1")), "O-O-O")
        let promo = Chess(fen: "4k3/1P6/8/8/8/8/8/4K3 w - - 0 1")!
        XCTAssertEqual(promo.describe(mv("b7b8", promo: 1)), "b8=Q+")
        let rooks = Chess(fen: "4k3/8/8/8/8/8/4K3/R6R w - - 0 1")!
        XCTAssertEqual(rooks.describe(mv("a1d1")), "Rad1")
    }

    func testStalemateIsDraw() throws {
        let chess = try play(["c1c7"], from: "k7/8/1K6/8/8/8/8/2Q5 w - - 0 1")
        XCTAssertEqual(chess.result, .draw)
        XCTAssertFalse(chess.isInCheck)
        XCTAssertEqual(Chess(fen: "k7/2Q5/1K6/8/8/8/8/8 b - - 0 1")!.result, .draw)
    }

    func testEnPassant() throws {
        let chess = try play(["e2e4", "a7a6", "e4e5", "d7d5"])
        XCTAssertEqual(chess.epSquare, Int(sq("d6")))
        XCTAssertTrue(chess.legalMoves().contains(mv("e5d6")))
        XCTAssertEqual(chess.describe(mv("e5d6")), "exd6")
        var after = chess
        try after.apply(mv("e5d6"))
        XCTAssertNil(after.piece(at: Int(sq("d5"))), "captured pawn is removed")
        XCTAssertEqual(after.piece(at: Int(sq("d6")))?.kind, .pawn)
        // The right lapses if not used at once.
        let later = try play(["e2e4", "a7a6", "e4e5", "d7d5", "a2a3", "a6a5"])
        XCTAssertFalse(later.legalMoves().contains(mv("e5d6")))
    }

    func testCastling() throws {
        let both = Chess(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        XCTAssertTrue(both.legalMoves().contains(mv("e1g1")))
        XCTAssertTrue(both.legalMoves().contains(mv("e1c1")))
        var castled = both
        try castled.apply(mv("e1g1"))
        XCTAssertEqual(castled.piece(at: Int(sq("f1")))?.kind, .rook)
        XCTAssertNil(castled.piece(at: Int(sq("h1"))))
        XCTAssertTrue(castled.legalMoves().contains(mv("e8c8")))
        // Passing through an attacked square (f1) is not allowed; queenside still is.
        let throughCheck = Chess(fen: "r4rk1/8/8/8/8/8/8/R3K2R w KQ - 0 1")!
        XCTAssertFalse(throughCheck.legalMoves().contains(mv("e1g1")))
        XCTAssertTrue(throughCheck.legalMoves().contains(mv("e1c1")))
        // Not while in check, and not after the king has moved.
        let inCheck = Chess(fen: "4r1k1/8/8/8/8/8/8/R3K2R w KQ - 0 1")!
        XCTAssertFalse(inCheck.legalMoves().contains(mv("e1g1")))
        let moved = try play(["e1f1", "g8f8", "f1e1", "f8g8"], from: "r5k1/8/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertFalse(moved.legalMoves().contains(mv("e1g1")))
        XCTAssertEqual(moved.castling, 0)
    }

    func testPromotionOffersFourPieces() {
        let chess = Chess(fen: "4k3/1P6/8/8/8/8/8/4K3 w - - 0 1")!
        let promos = chess.legalMoves().filter { $0[0] == sq("b7") && $0[1] == sq("b8") }
        XCTAssertEqual(Set(promos.map { $0[2] }), [1, 2, 3, 4])
        XCTAssertFalse(chess.legalMoves().contains(mv("b7b8")), "a bare promotion move is illegal")
    }

    func testIllegalAndMalformedMovesThrow() {
        var chess = Chess(options: Data())
        XCTAssertThrowsError(try chess.apply(mv("e2e5"))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        XCTAssertThrowsError(try chess.apply(mv("e7e5"))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        XCTAssertThrowsError(try chess.apply(Data([12, 28]))) { XCTAssertEqual($0 as? GameError, .malformedMove) }
        XCTAssertThrowsError(try chess.apply(Data([200, 28, 0]))) { XCTAssertEqual($0 as? GameError, .illegalMove) }
        // A pinned piece may not move off the pin line.
        let pinned = Chess(fen: "4k3/4r3/8/8/8/8/4N3/4K3 w - - 0 1")!
        XCTAssertFalse(pinned.legalMoves().contains(mv("e2c3")))
        XCTAssertEqual(chess.canonical, Chess(options: Data()).canonical, "failed moves leave state untouched")
    }

    func testReplayReproducesCanonical() throws {
        let moves = ["e2e4", "c7c5", "g1f3", "d7d6", "d2d4", "c5d4", "f3d4", "g8f6", "b1c3", "a7a6"]
        let stepwise = try play(moves)
        let log = moves.reduce(Data()) { $0 + mv($1) }
        let replayed = try GameKind.chess.replay(options: Data([0]), moves: log)
        XCTAssertEqual(replayed.canonical, stepwise.canonical)
        XCTAssertEqual(StateHash.of(replayed), StateHash.of(stepwise))
        XCTAssertEqual(replayed.toMove, .one)
        XCTAssertEqual(replayed.canonical.count, 68)
        XCTAssertNotEqual(replayed.canonical, Chess(options: Data()).canonical)
    }

    func testThreefoldRepetitionIsDraw() throws {
        let shuffle = ["g1f3", "g8f6", "f3g1", "f6g8"]
        let twice = try play(shuffle + shuffle.dropLast())
        XCTAssertNil(twice.result)
        let thrice = try play(shuffle + shuffle)
        XCTAssertEqual(thrice.result, .draw)
    }

    func testFiftyMoveRuleAndInsufficientMaterial() throws {
        let clock = try play(["e1e2"], from: "4k3/8/8/8/8/8/8/R3K3 w - - 99 1")
        XCTAssertEqual(clock.result, .draw)
        XCTAssertNil(Chess(fen: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1")!.result)
        XCTAssertEqual(Chess(fen: "4k3/8/8/8/8/8/8/4KB2 w - - 0 1")!.result, .draw)
        XCTAssertEqual(Chess(fen: "4k3/8/8/8/8/8/8/4KN2 w - - 0 1")!.result, .draw)
        XCTAssertEqual(Chess(fen: "4kb2/8/8/8/8/8/8/4K1B1 w - - 0 1")!.result, .draw, "same-colour bishops")
        XCTAssertNil(Chess(fen: "4k1b1/8/8/8/8/8/8/4K1B1 w - - 0 1")!.result, "opposite-colour bishops")
        // Capturing down to bare kings ends the game.
        let bare = try play(["e1d1"], from: "4k3/8/8/8/8/8/8/3rK3 w - - 0 1")
        XCTAssertEqual(bare.result, .draw)
    }

    func testViewHelpers() throws {
        let chess = try play(["e2e4"])
        XCTAssertEqual(chess.lastMove?.from, Int(sq("e2")))
        XCTAssertEqual(chess.lastMove?.to, Int(sq("e4")))
        XCTAssertEqual(chess.piece(at: Int(sq("e4")))?.player, .one)
        XCTAssertEqual(chess.piece(at: Int(sq("e8")))?.kind, .king)
        XCTAssertEqual(chess.kingSquare(.two), Int(sq("e8")))
        XCTAssertNil(chess.piece(at: 64))
        XCTAssertEqual(chess.toMove, .two)
        XCTAssertEqual(Chess.name(of: 63), "h8")
        XCTAssertEqual(Chess.square(named: "a1"), 0)
    }
}
