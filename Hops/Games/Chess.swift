import Foundation

/// Chess (docs/GAMES.md §5.4). Player.one is White and moves first.
///
/// Squares are 0–63 with a1 = 0, b1 = 1, … h8 = 63. A move is three bytes:
/// from, to, promotion (0 none, 1 queen, 2 rook, 3 bishop, 4 knight).
/// Castling is encoded as the king's two-square move. The board is a plain
/// 64-byte mailbox: 0 empty, 1–6 white P N B R Q K, 9–14 black (bit 3 set).
struct Chess: GameEngine {
    enum Kind: UInt8 { case pawn = 1, knight, bishop, rook, queen, king }

    struct Move: Hashable {
        var from: Int, to: Int, promo: UInt8
        var data: Data { Data([UInt8(from), UInt8(to), promo]) }
        init(from: Int, to: Int, promo: UInt8 = 0) { self.from = from; self.to = to; self.promo = promo }
        init?(_ data: Data) {
            guard data.count == 3 else { return nil }
            let b = [UInt8](data)
            self.init(from: Int(b[0]), to: Int(b[1]), promo: b[2])
        }
    }

    private(set) var board: [UInt8]
    private(set) var toMove: Player
    /// Castling rights: bit 0 white K, 1 white Q, 2 black k, 3 black q.
    private(set) var castling: UInt8
    /// En passant target square, or -1. Only set when a capture is possible.
    private(set) var epSquare: Int
    private(set) var halfmoveClock: Int
    private(set) var result: GameResult?
    private(set) var lastMove: (from: Int, to: Int)?
    /// Position key → occurrences, for threefold repetition.
    private var seen: [[UInt8]: Int]

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    /// Options byte 0 (which side the inviter plays) is the coordinator's
    /// business; the engine itself has no options.
    init(options: Data) { self.init(fen: Self.startFEN)! }

    /// Forsyth–Edwards notation, for tests and fixtures.
    init?(fen: String) {
        let parts = fen.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        let codes: [Character: UInt8] = ["P": 1, "N": 2, "B": 3, "R": 4, "Q": 5, "K": 6,
                                         "p": 9, "n": 10, "b": 11, "r": 12, "q": 13, "k": 14]
        var b = [UInt8](repeating: 0, count: 64)
        var rank = 7, file = 0
        for ch in parts[0] {
            if ch == "/" { rank -= 1; file = 0; continue }
            if let skip = ch.wholeNumberValue { file += skip; continue }
            guard let code = codes[ch], rank >= 0, file < 8 else { return nil }
            b[rank * 8 + file] = code
            file += 1
        }
        board = b
        toMove = parts[1] == "b" ? .two : .one
        castling = 0
        for c in parts.count > 2 ? parts[2] : "-" {
            switch c {
            case "K": castling |= 1
            case "Q": castling |= 2
            case "k": castling |= 4
            case "q": castling |= 8
            default: break
            }
        }
        epSquare = parts.count > 3 ? (Self.square(named: parts[3]) ?? -1) : -1
        halfmoveClock = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
        result = nil
        lastMove = nil
        seen = [:]
        seen[positionKey] = 1
        updateResult()
    }

    // MARK: - GameEngine

    var canonical: Data { Data(positionKey + [UInt8(min(halfmoveClock, 255))]) }

    func legalMoves() -> [Data] { result == nil ? legal().map(\.data) : [] }

    mutating func apply(_ move: Data) throws {
        guard let m = Move(move) else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        guard isLegal(m) else { throw GameError.illegalMove }
        let piece = board[m.from]
        let isPawn = piece & 7 == 1
        let capture = board[m.to] != 0 || (isPawn && m.to == epSquare)
        Self.play(m, on: &board, ep: epSquare)
        halfmoveClock = (isPawn || capture) ? 0 : halfmoveClock + 1
        castling &= ~(Self.rightsTouched(by: m.from) | Self.rightsTouched(by: m.to))
        epSquare = -1
        if isPawn && abs(m.to - m.from) == 16 {
            let enemyPawn = (piece & 8) ^ 8 | 1
            let file = m.to & 7
            if (file > 0 && board[m.to - 1] == enemyPawn) || (file < 7 && board[m.to + 1] == enemyPawn) {
                epSquare = (m.from + m.to) / 2
            }
        }
        lastMove = (m.from, m.to)
        toMove = toMove.other
        seen[positionKey, default: 0] += 1
        updateResult()
    }

    /// Short algebraic notation ("Nf3", "exd5", "O-O", "e8=Q", "Qxf7#"),
    /// evaluated against the current position, i.e. before the move is applied.
    func describe(_ move: Data) -> String {
        guard let m = Move(move), m.from < 64, m.to < 64 else { return "?" }
        let fallback = "\(Self.name(of: m.from))–\(Self.name(of: m.to))"
        let piece = board[m.from]
        let moves = legal()
        guard piece != 0, result == nil, moves.contains(m) else { return fallback }
        var san: String
        if piece & 7 == 6 && abs(m.to - m.from) == 2 {
            san = m.to > m.from ? "O-O" : "O-O-O"
        } else {
            let capture = board[m.to] != 0 || (piece & 7 == 1 && m.to == epSquare)
            if piece & 7 == 1 {
                san = capture ? String(Self.name(of: m.from).prefix(1)) : ""
            } else {
                san = ["", "", "N", "B", "R", "Q", "K"][Int(piece & 7)]
                let others = moves.filter { $0.to == m.to && $0.from != m.from && board[$0.from] == piece }
                if !others.isEmpty {
                    let from = Self.name(of: m.from)
                    if !others.contains(where: { $0.from & 7 == m.from & 7 }) { san += from.prefix(1) }
                    else if !others.contains(where: { $0.from >> 3 == m.from >> 3 }) { san += from.suffix(1) }
                    else { san += from }
                }
            }
            if capture { san += "x" }
            san += Self.name(of: m.to)
            if m.promo != 0 { san += "=" + ["", "Q", "R", "B", "N"][Int(m.promo)] }
        }
        var next = self
        try? next.apply(move)
        if next.isInCheck {
            if case .win = next.result { san += "#" } else { san += "+" }
        }
        return san
    }

    // MARK: - Read-only helpers for views

    func piece(at square: Int) -> (player: Player, kind: Kind)? {
        guard (0..<64).contains(square), let kind = Kind(rawValue: board[square] & 7) else { return nil }
        return (board[square] & 8 == 0 ? .one : .two, kind)
    }

    func kingSquare(_ player: Player) -> Int? {
        board.firstIndex(of: player == .one ? 6 : 14)
    }

    /// Is the side to move in check?
    var isInCheck: Bool {
        guard let k = kingSquare(toMove) else { return false }
        return Self.attacked(k, by: toMove == .one ? 8 : 0, on: board)
    }

    static func name(of square: Int) -> String {
        let files = Array("abcdefgh")
        return "\(files[square & 7])\((square >> 3) + 1)"
    }

    static func square(named name: String) -> Int? {
        let chars = Array(name)
        guard chars.count == 2, let f = "abcdefgh".firstIndex(of: chars[0]),
              let r = chars[1].wholeNumberValue, (1...8).contains(r) else { return nil }
        return (r - 1) * 8 + "abcdefgh".distance(from: "abcdefgh".startIndex, to: f)
    }

    // MARK: - Move generation

    private static let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookDirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    private static let bishopDirs = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    private static let promoCodes: [UInt8] = [0, 5, 4, 3, 2]

    /// Legal moves for the side to move, ignoring `result`.
    private func legal() -> [Move] {
        var out: [Move] = [], scratch = board
        out.reserveCapacity(64)
        let us: UInt8 = toMove == .one ? 0 : 8, king = kingSquare(toMove)
        for from in 0..<64 where board[from] != 0 && board[from] & 8 == us {
            pseudoMoves(from: from, into: &out)
        }
        return out.filter { isLegal($0, king: king, scratch: &scratch) }
    }

    private func isLegal(_ m: Move) -> Bool {
        guard m.from < 64, m.to < 64, board[m.from] != 0, board[m.from] & 8 == (toMove == .one ? 0 : 8) else { return false }
        var out: [Move] = [], scratch = board
        pseudoMoves(from: m.from, into: &out)
        return out.contains(m) && isLegal(m, king: kingSquare(toMove), scratch: &scratch)
    }

    private func hasLegalMove() -> Bool {
        var out: [Move] = [], scratch = board
        let us: UInt8 = toMove == .one ? 0 : 8, king = kingSquare(toMove)
        for from in 0..<64 where board[from] != 0 && board[from] & 8 == us {
            out.removeAll(keepingCapacity: true)
            pseudoMoves(from: from, into: &out)
            if out.contains(where: { isLegal($0, king: king, scratch: &scratch) }) { return true }
        }
        return false
    }

    /// Plays `m` on `scratch` (a copy of `board`), tests the king, and undoes it.
    private func isLegal(_ m: Move, king: Int?, scratch b: inout [UInt8]) -> Bool {
        guard let king else { return true }
        let fromPiece = b[m.from], toPiece = b[m.to]
        let (extraSquare, extraPiece) = Self.play(m, on: &b, ep: epSquare)
        let ok = !Self.attacked(m.from == king ? m.to : king, by: (fromPiece & 8) ^ 8, on: b)
        if fromPiece & 7 == 6 && abs(m.to - m.from) == 2 { b[(m.from + m.to) / 2] = 0 }   // castling rook
        b[extraSquare] = extraPiece
        b[m.to] = toPiece
        b[m.from] = fromPiece
        return ok
    }

    /// Pseudo-legal moves of the piece on `from` (own king may be left in check).
    private func pseudoMoves(from: Int, into out: inout [Move]) {
        let p = board[from]
        let us = p & 8, them = us ^ 8
        func isEnemy(_ p: UInt8) -> Bool { p != 0 && p & 8 == them }
        func step(_ deltas: [(Int, Int)]) {
            let f = from & 7, r = from >> 3
            for (df, dr) in deltas {
                let nf = f + df, nr = r + dr
                guard nf >= 0, nf < 8, nr >= 0, nr < 8 else { continue }
                let to = nr * 8 + nf
                if board[to] == 0 || isEnemy(board[to]) { out.append(Move(from: from, to: to)) }
            }
        }
        func slide(_ dirs: [(Int, Int)]) {
            let f = from & 7, r = from >> 3
            for (df, dr) in dirs {
                var nf = f + df, nr = r + dr
                while nf >= 0, nf < 8, nr >= 0, nr < 8 {
                    let to = nr * 8 + nf
                    let p = board[to]
                    if p == 0 || isEnemy(p) { out.append(Move(from: from, to: to)) }
                    if p != 0 { break }
                    nf += df; nr += dr
                }
            }
        }
        func pawn(_ to: Int, _ promoRank: Int) {
            if to >> 3 == promoRank {
                for promo: UInt8 in 1...4 { out.append(Move(from: from, to: to, promo: promo)) }
            } else {
                out.append(Move(from: from, to: to))
            }
        }
        switch p & 7 {
        case 1:
            let dir = us == 0 ? 8 : -8
            let startRank = us == 0 ? 1 : 6, promoRank = us == 0 ? 7 : 0
            let to = from + dir
            guard to >= 0, to < 64 else { break }
            if board[to] == 0 {
                pawn(to, promoRank)
                if from >> 3 == startRank && board[to + dir] == 0 { out.append(Move(from: from, to: to + dir)) }
            }
            let f = from & 7
            if f > 0, isEnemy(board[to - 1]) || to - 1 == epSquare { pawn(to - 1, promoRank) }
            if f < 7, isEnemy(board[to + 1]) || to + 1 == epSquare { pawn(to + 1, promoRank) }
        case 2: step(Self.knightSteps)
        case 3: slide(Self.bishopDirs)
        case 4: slide(Self.rookDirs)
        case 5: slide(Self.rookDirs); slide(Self.bishopDirs)
        case 6:
            step(Self.kingSteps)
            let home = us == 0 ? 4 : 60
            guard from == home, !Self.attacked(home, by: them, on: board) else { break }
            let kSide: UInt8 = us == 0 ? 1 : 4, qSide: UInt8 = us == 0 ? 2 : 8
            if castling & kSide != 0, board[home + 1] == 0, board[home + 2] == 0,
               !Self.attacked(home + 1, by: them, on: board), !Self.attacked(home + 2, by: them, on: board) {
                out.append(Move(from: home, to: home + 2))
            }
            if castling & qSide != 0, board[home - 1] == 0, board[home - 2] == 0, board[home - 3] == 0,
               !Self.attacked(home - 1, by: them, on: board), !Self.attacked(home - 2, by: them, on: board) {
                out.append(Move(from: home, to: home - 2))
            }
        default: break
        }
    }

    /// Moves the piece on the board only (en passant capture, castling rook,
    /// promotion included); rights and clocks are the caller's job. Returns
    /// the one square other than from/to it changed, with its old contents,
    /// so a caller can undo.
    @discardableResult
    private static func play(_ m: Move, on b: inout [UInt8], ep: Int) -> (Int, UInt8) {
        let p = b[m.from]
        var extra = (m.from, p)
        b[m.from] = 0
        if p & 7 == 1 {
            if m.to == ep {
                let captured = m.to + (p & 8 == 0 ? -8 : 8)
                extra = (captured, b[captured])
                b[captured] = 0
            }
        } else if p & 7 == 6 && abs(m.to - m.from) == 2 {
            let (rookFrom, rookTo) = m.to > m.from ? (m.to + 1, m.to - 1) : (m.to - 2, m.to + 1)
            extra = (rookFrom, b[rookFrom])
            b[rookTo] = b[rookFrom]
            b[rookFrom] = 0
        }
        b[m.to] = m.promo == 0 ? p : (p & 8) | promoCodes[Int(m.promo)]
        return extra
    }

    /// Is `square` attacked by the side whose colour bit is `color` (0 / 8)?
    private static func attacked(_ square: Int, by color: UInt8, on b: [UInt8]) -> Bool {
        let f = square & 7, r = square >> 3
        let pawnRank = color == 0 ? r - 1 : r + 1
        if pawnRank >= 0 && pawnRank < 8 {
            if f > 0 && b[pawnRank * 8 + f - 1] == color | 1 { return true }
            if f < 7 && b[pawnRank * 8 + f + 1] == color | 1 { return true }
        }
        for (df, dr) in knightSteps {
            let nf = f + df, nr = r + dr
            if nf >= 0, nf < 8, nr >= 0, nr < 8, b[nr * 8 + nf] == color | 2 { return true }
        }
        for (df, dr) in kingSteps {
            let nf = f + df, nr = r + dr
            if nf >= 0, nf < 8, nr >= 0, nr < 8, b[nr * 8 + nf] == color | 6 { return true }
        }
        for (df, dr) in kingSteps {
            let slider: UInt8 = (df == 0 || dr == 0) ? color | 4 : color | 3
            var nf = f + df, nr = r + dr
            while nf >= 0, nf < 8, nr >= 0, nr < 8 {
                let p = b[nr * 8 + nf]
                if p != 0 {
                    if p == slider || p == color | 5 { return true }
                    break
                }
                nf += df; nr += dr
            }
        }
        return false
    }

    /// Castling rights lost when a move starts or ends on `square`.
    private static func rightsTouched(by square: Int) -> UInt8 {
        switch square {
        case 4: return 3
        case 7: return 1
        case 0: return 2
        case 60: return 12
        case 63: return 4
        case 56: return 8
        default: return 0
        }
    }

    // MARK: - Result

    private var positionKey: [UInt8] {
        board + [toMove.rawValue, castling, epSquare < 0 ? 255 : UInt8(epSquare & 7)]
    }

    private mutating func updateResult() {
        if !hasLegalMove() {
            result = isInCheck ? .win(toMove.other) : .draw
        } else if halfmoveClock >= 100 || seen[positionKey, default: 0] >= 3 || insufficientMaterial {
            result = .draw
        }
    }

    /// K v K, K+B v K, K+N v K, and bishops (any number, either side) all on
    /// one square colour.
    private var insufficientMaterial: Bool {
        var minors = 0, knights = 0, bishopColours: Set<Int> = []
        for s in 0..<64 {
            switch board[s] & 7 {
            case 0, 6: continue
            case 2: knights += 1; minors += 1
            case 3: bishopColours.insert((s + (s >> 3)) & 1); minors += 1
            default: return false
            }
        }
        return minors <= 1 || (knights == 0 && bishopColours.count == 1)
    }
}
