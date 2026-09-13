import Foundation

/// American checkers (draughts) on the 32 dark squares of an 8×8 board.
///
/// Square `s` (0–31) sits on row `s / 4` (row 0 at the top) and column
/// `2 * (s % 4) + (row even ? 1 : 0)`, which matches standard notation once
/// you add one. Player.one starts on squares 20–31 (the bottom three rows),
/// moves first and moves up the board; Player.two starts on 0–11 and moves
/// down. A move is 2 bytes: from square, to square. A multi-jump is a
/// sequence of such moves by the same player; `toMove` does not change until
/// the jumping piece has no further capture (or is crowned).
struct Checkers: GameEngine {
    // Square contents.
    static let empty: UInt8 = 0, oneMan: UInt8 = 1, oneKing: UInt8 = 2, twoMan: UInt8 = 3, twoKing: UInt8 = 4

    private(set) var squares: [UInt8]
    private(set) var toMove: Player
    /// Square of the piece in the middle of a multi-jump, if any.
    private(set) var jumping: Int?
    /// Consecutive king moves with no capture; 40 is a draw.
    private(set) var quietKingMoves: Int

    static let startSquares: [UInt8] = (0..<32).map { $0 < 12 ? twoMan : ($0 >= 20 ? oneMan : empty) }

    init(options: Data) {
        self.init(squares: Checkers.startSquares, toMove: .one)
    }

    /// Any position — for tests and for constructing puzzles.
    init(squares: [UInt8], toMove: Player, quietKingMoves: Int = 0) {
        precondition(squares.count == 32)
        self.squares = squares
        self.toMove = toMove
        self.jumping = nil
        self.quietKingMoves = quietKingMoves
    }

    // MARK: Geometry

    static func row(_ s: Int) -> Int { s / 4 }
    static func col(_ s: Int) -> Int { 2 * (s % 4) + (s / 4 % 2 == 0 ? 1 : 0) }
    /// The dark square at (row, col), or nil for light squares and off-board.
    static func square(row: Int, col: Int) -> Int? {
        guard (0..<8).contains(row), (0..<8).contains(col), (row + col) % 2 == 1 else { return nil }
        return row * 4 + col / 2
    }
    static func owner(_ v: UInt8) -> Player? { v == empty ? nil : (v <= oneKing ? .one : .two) }
    static func isKing(_ v: UInt8) -> Bool { v == oneKing || v == twoKing }

    // MARK: Rules

    private static func directions(for v: UInt8) -> [(Int, Int)] {
        if isKing(v) { return [(-1, -1), (-1, 1), (1, -1), (1, 1)] }
        let dr = owner(v) == .one ? -1 : 1   // men only move forward
        return [(dr, -1), (dr, 1)]
    }

    private func jumps(from s: Int) -> [Data] {
        let v = squares[s]
        guard let me = Checkers.owner(v) else { return [] }
        let r = Checkers.row(s), c = Checkers.col(s)
        return Checkers.directions(for: v).compactMap { dr, dc in
            guard let over = Checkers.square(row: r + dr, col: c + dc),
                  let to = Checkers.square(row: r + 2 * dr, col: c + 2 * dc),
                  Checkers.owner(squares[over]) == me.other, squares[to] == Checkers.empty
            else { return nil }
            return Data([UInt8(s), UInt8(to)])
        }
    }

    private func steps(from s: Int) -> [Data] {
        let v = squares[s]
        let r = Checkers.row(s), c = Checkers.col(s)
        return Checkers.directions(for: v).compactMap { dr, dc in
            guard let to = Checkers.square(row: r + dr, col: c + dc), squares[to] == Checkers.empty else { return nil }
            return Data([UInt8(s), UInt8(to)])
        }
    }

    /// Captures are mandatory; mid multi-jump only the jumping piece may move.
    func legalMoves() -> [Data] {
        if let j = jumping { return jumps(from: j) }
        let mine = (0..<32).filter { Checkers.owner(squares[$0]) == toMove }
        let captures = mine.flatMap(jumps)
        return captures.isEmpty ? mine.flatMap(steps) : captures
    }

    var result: GameResult? {
        if legalMoves().isEmpty { return .win(toMove.other) }   // no pieces or all blocked
        if quietKingMoves >= 40 { return .draw }
        return nil
    }

    mutating func apply(_ move: Data) throws {
        guard move.count == 2 else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        guard legalMoves().contains(move) else { throw GameError.illegalMove }
        let b = [UInt8](move)
        let from = Int(b[0]), to = Int(b[1])
        let piece = squares[from]
        let isJump = abs(Checkers.row(to) - Checkers.row(from)) == 2
        squares[from] = Checkers.empty
        if isJump {
            let over = Checkers.square(row: (Checkers.row(from) + Checkers.row(to)) / 2,
                                       col: (Checkers.col(from) + Checkers.col(to)) / 2)!
            squares[over] = Checkers.empty
            quietKingMoves = 0
        } else {
            quietKingMoves = Checkers.isKing(piece) ? quietKingMoves + 1 : 0
        }
        // Reaching the far row crowns the man and ends its turn even mid-jump.
        let promotes = !Checkers.isKing(piece) && Checkers.row(to) == (toMove == .one ? 0 : 7)
        squares[to] = promotes ? piece + 1 : piece
        if isJump, !promotes, !jumps(from: to).isEmpty {
            jumping = to
        } else {
            jumping = nil
            toMove = toMove.other
        }
    }

    /// "12–16" for a step, "12×19" for a jump, 1-based like printed notation.
    func describe(_ move: Data) -> String {
        let b = [UInt8](move)
        guard b.count == 2, b[0] < 32, b[1] < 32 else { return "?" }
        let jump = abs(Checkers.row(Int(b[0])) - Checkers.row(Int(b[1]))) == 2
        return "\(b[0] + 1)\(jump ? "×" : "–")\(b[1] + 1)"
    }

    /// 32 square bytes + toMove + mid-jump square (255 = none) + quiet counter.
    var canonical: Data {
        var d = Data(squares)
        d.append(toMove.rawValue)
        d.append(UInt8(jumping ?? 255))
        d.append(UInt8(min(quietKingMoves, 255)))
        return d
    }
}
