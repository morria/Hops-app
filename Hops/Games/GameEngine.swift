import Foundation

// MARK: - Two-player turn-based game engines (docs/GAMES.md §3)
//
// A game is a pure state machine rebuilt from its move log. Engines never
// see the network: they answer "whose turn", "which moves are legal",
// "apply this move", and "encode this state canonically" so both phones
// can hash it and agree.

enum Player: UInt8, Codable, Equatable {
    case one = 0, two = 1
    var other: Player { self == .one ? .two : .one }
}

enum GameResult: Equatable, Codable {
    case win(Player)
    case draw
}

enum GameError: Error, Equatable {
    case illegalMove
    case malformedMove
    case gameOver
}

protocol GameEngine {
    /// Fresh state. `options` are the invite's game options bytes
    /// (byte 0 = which side the inviter plays; the rest is game-specific).
    init(options: Data)
    var toMove: Player { get }
    var result: GameResult? { get }
    /// Deterministic encoding of the public state — both sides hash this.
    var canonical: Data { get }
    /// Every legal move for the player to move, each exactly `moveSize` bytes.
    func legalMoves() -> [Data]
    mutating func apply(_ move: Data) throws
    /// Human-readable move for the log ("e2–e4", "column 4").
    func describe(_ move: Data) -> String
    /// Some games need a hidden, local setup before play (Battleship's ship
    /// placement). The coordinator keeps it in the session's private data.
    static var needsPrivateSetup: Bool { get }
    /// A move the engine can make on the player's behalf from private data
    /// (Battleship's hit/miss report). nil = the human must choose.
    func autoMove(privateData: Data) -> Data?
}

extension GameEngine {
    static var needsPrivateSetup: Bool { false }
    func autoMove(privateData: Data) -> Data? { nil }
    var isOver: Bool { result != nil }
}

/// The wire id (INVITE byte 6), display metadata, and the factory.
enum GameKind: UInt8, CaseIterable, Codable {
    case ticTacToe = 1
    case connectFour = 2
    case dotsAndBoxes = 3
    case checkers = 4
    case battleship = 5
    case chess = 6

    var title: String {
        switch self {
        case .ticTacToe: return "Tic-Tac-Toe"
        case .connectFour: return "Connect Four"
        case .dotsAndBoxes: return "Dots and Boxes"
        case .checkers: return "Checkers"
        case .battleship: return "Battleship"
        case .chess: return "Chess"
        }
    }

    var subtitle: String {
        switch self {
        case .ticTacToe: return "Three in a row on a 3×3 grid"
        case .connectFour: return "Drop discs, connect four"
        case .dotsAndBoxes: return "Claim boxes on a 4×4 grid"
        case .checkers: return "American draughts, 8×8"
        case .battleship: return "Hidden fleets, 10×10"
        case .chess: return "The full game, 8×8"
        }
    }

    var icon: String {
        switch self {
        case .ticTacToe: return "number"
        case .connectFour: return "circle.grid.3x3.fill"
        case .dotsAndBoxes: return "square.grid.3x3"
        case .checkers: return "circle.circle"
        case .battleship: return "sailboat"
        case .chess: return "crown"
        }
    }

    /// Fixed-width move encoding, in bytes.
    var moveSize: Int {
        switch self {
        case .ticTacToe, .connectFour, .dotsAndBoxes, .battleship: return 1
        case .checkers: return 2
        case .chess: return 3
        }
    }

    func make(options: Data) -> any GameEngine {
        switch self {
        case .ticTacToe: return TicTacToe(options: options)
        case .connectFour: return ConnectFour(options: options)
        case .dotsAndBoxes: return DotsAndBoxes(options: options)
        case .checkers: return Checkers(options: options)
        case .battleship: return Battleship(options: options)
        case .chess: return Chess(options: options)
        }
    }

    var needsPrivateSetup: Bool {
        switch self {
        case .ticTacToe: return TicTacToe.needsPrivateSetup
        case .connectFour: return ConnectFour.needsPrivateSetup
        case .dotsAndBoxes: return DotsAndBoxes.needsPrivateSetup
        case .checkers: return Checkers.needsPrivateSetup
        case .battleship: return Battleship.needsPrivateSetup
        case .chess: return Chess.needsPrivateSetup
        }
    }

    /// Replays a move log. Throws on the first illegal move.
    func replay(options: Data, moves: Data) throws -> any GameEngine {
        var engine = make(options: options)
        var offset = 0
        while offset + moveSize <= moves.count {
            try engine.apply(moves.subdata(in: offset..<(offset + moveSize)))
            offset += moveSize
        }
        return engine
    }
}

/// FNV-1a 32-bit — tiny, endian-free, good enough to detect divergence.
enum StateHash {
    static func fnv1a(_ data: Data) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
    static func of(_ engine: any GameEngine) -> UInt32 { fnv1a(engine.canonical) }
}

// MARK: - Byte helpers shared by engines and the protocol

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
    func uint16(at offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        let b = [UInt8](self[(startIndex + offset)..<(startIndex + offset + 2)])
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    func uint32(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        let b = [UInt8](self[(startIndex + offset)..<(startIndex + offset + 4)])
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}
