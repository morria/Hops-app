import Foundation

// MARK: - Tic-Tac-Toe (move = cell 0…8)

struct TicTacToe: GameEngine {
    /// 0 empty, 1 = Player.one, 2 = Player.two.
    private(set) var cells = [UInt8](repeating: 0, count: 9)
    private(set) var toMove: Player = .one
    private(set) var result: GameResult?

    init(options: Data) {}

    static let lines: [[Int]] = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    var canonical: Data { Data(cells) + [toMove.rawValue] }

    func legalMoves() -> [Data] {
        guard result == nil else { return [] }
        return cells.indices.filter { cells[$0] == 0 }.map { Data([UInt8($0)]) }
    }

    mutating func apply(_ move: Data) throws {
        guard move.count == 1 else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        let cell = Int(move[move.startIndex])
        guard cell < 9, cells[cell] == 0 else { throw GameError.illegalMove }
        cells[cell] = toMove.rawValue + 1
        let mark = toMove.rawValue + 1
        if Self.lines.contains(where: { $0.allSatisfy { cells[$0] == mark } }) {
            result = .win(toMove)
        } else if !cells.contains(0) {
            result = .draw
        }
        toMove = toMove.other
    }

    func describe(_ move: Data) -> String {
        guard let cell = move.first, cell < 9 else { return "?" }
        return "\(["top", "middle", "bottom"][Int(cell) / 3]) \(["left", "center", "right"][Int(cell) % 3])"
    }
}

// MARK: - Connect Four (move = column 0…6)

struct ConnectFour: GameEngine {
    static let columns = 7, rows = 6
    /// Row-major from the bottom row up; 0 empty, 1/2 players.
    private(set) var cells = [UInt8](repeating: 0, count: 42)
    private(set) var toMove: Player = .one
    private(set) var result: GameResult?
    private(set) var lastCell: Int = -1

    init(options: Data) {}

    var canonical: Data { Data(cells) + [toMove.rawValue] }

    func cell(row: Int, column: Int) -> UInt8 { cells[row * Self.columns + column] }

    private func landingRow(column: Int) -> Int? {
        (0..<Self.rows).first { cell(row: $0, column: column) == 0 }
    }

    func legalMoves() -> [Data] {
        guard result == nil else { return [] }
        return (0..<Self.columns).filter { landingRow(column: $0) != nil }.map { Data([UInt8($0)]) }
    }

    mutating func apply(_ move: Data) throws {
        guard move.count == 1 else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        let column = Int(move[move.startIndex])
        guard column < Self.columns, let row = landingRow(column: column) else { throw GameError.illegalMove }
        let mark = toMove.rawValue + 1
        cells[row * Self.columns + column] = mark
        lastCell = row * Self.columns + column
        if connects(row: row, column: column, mark: mark) {
            result = .win(toMove)
        } else if !cells.contains(0) {
            result = .draw
        }
        toMove = toMove.other
    }

    private func connects(row: Int, column: Int, mark: UInt8) -> Bool {
        for (dr, dc) in [(0, 1), (1, 0), (1, 1), (1, -1)] {
            var run = 1
            for sign in [1, -1] {
                var r = row + dr * sign, c = column + dc * sign
                while r >= 0, r < Self.rows, c >= 0, c < Self.columns, cell(row: r, column: c) == mark {
                    run += 1; r += dr * sign; c += dc * sign
                }
            }
            if run >= 4 { return true }
        }
        return false
    }

    func describe(_ move: Data) -> String {
        guard let column = move.first else { return "?" }
        return "column \(Int(column) + 1)"
    }
}

// MARK: - Dots and Boxes, 4×4 boxes (move = edge index 0…39)
//
// Edges: 20 horizontal (5 rows × 4) indexed 0…19 as row*4+col, then 20
// vertical (4 rows × 5) indexed 20 + row*5 + col. Completing a box gives the
// mover another turn.

struct DotsAndBoxes: GameEngine {
    static let size = 4
    static let edgeCount = 40
    private(set) var edges = [Bool](repeating: false, count: 40)
    /// 0 unclaimed, 1/2 owner. Row-major.
    private(set) var boxes = [UInt8](repeating: 0, count: 16)
    private(set) var toMove: Player = .one
    private(set) var result: GameResult?

    init(options: Data) {}

    var canonical: Data {
        Data(edges.map { $0 ? 1 : 0 }) + Data(boxes) + [toMove.rawValue]
    }

    static func horizontal(row: Int, col: Int) -> Int { row * size + col }
    static func vertical(row: Int, col: Int) -> Int { 20 + row * (size + 1) + col }

    static func edgesOf(box row: Int, _ col: Int) -> [Int] {
        [horizontal(row: row, col: col), horizontal(row: row + 1, col: col),
         vertical(row: row, col: col), vertical(row: row, col: col + 1)]
    }

    func score(_ player: Player) -> Int { boxes.filter { $0 == player.rawValue + 1 }.count }

    func legalMoves() -> [Data] {
        guard result == nil else { return [] }
        return edges.indices.filter { !edges[$0] }.map { Data([UInt8($0)]) }
    }

    mutating func apply(_ move: Data) throws {
        guard move.count == 1 else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        let edge = Int(move[move.startIndex])
        guard edge < Self.edgeCount, !edges[edge] else { throw GameError.illegalMove }
        edges[edge] = true
        var claimed = false
        for row in 0..<Self.size {
            for col in 0..<Self.size where boxes[row * Self.size + col] == 0 {
                let sides = Self.edgesOf(box: row, col)
                if sides.contains(edge), sides.allSatisfy({ edges[$0] }) {
                    boxes[row * Self.size + col] = toMove.rawValue + 1
                    claimed = true
                }
            }
        }
        if !boxes.contains(0) {
            let one = score(.one), two = score(.two)
            result = one == two ? .draw : .win(one > two ? .one : .two)
        }
        if !claimed { toMove = toMove.other }
    }

    func describe(_ move: Data) -> String {
        guard let edge = move.first else { return "?" }
        let e = Int(edge)
        if e < 20 { return "row \(e / 4 + 1), line \(e % 4 + 1)" }
        return "column \((e - 20) % 5 + 1), line \((e - 20) / 5 + 1)"
    }
}
