import Foundation

// MARK: - Games wire protocol, port 425 (docs/GAMES.md §2)
//
// Pure: no radio, no persistence. `GameSessionRecord` is the whole truth
// about one game; `GameLogic` turns (record, frame) into (record', replies,
// events). The coordinator persists records and sends frames.

enum GamePhase: String, Codable {
    case inviting      // I sent INVITE, no answer yet
    case invited       // they invited me; Accept/Decline pending
    case myTurn
    case waiting       // my MOVE is out; waiting for their ACK with a matching hash
    case theirTurn
    case finished
    case declined      // they declined, or I did
}

enum GameEndReason: UInt8, Codable {
    case resign = 1, drawOffer = 2, drawAccept = 3, abandon = 4
}

enum GameNakReason: UInt8 {
    case unknownSession = 1, wrongPrevHash = 2, illegalMove = 3, notYourTurn = 4, gameOver = 5

    var text: String {
        switch self {
        case .unknownSession: return "They don't have this game"
        case .wrongPrevHash: return "Out of sync — boards differ"
        case .illegalMove: return "They rejected the move as illegal"
        case .notYourTurn: return "They say it isn't your turn"
        case .gameOver: return "They say the game is over"
        }
    }
}

struct GameSessionRecord: Equatable {
    var id: UInt32
    var kind: GameKind
    var peer: Int64
    var me: Player
    var options: Data
    var moves = Data()
    var phase: GamePhase
    /// My move in flight (phase == .waiting); becomes moves[seq] on agreement.
    var pending: Data?
    var result: GameResult?
    var endReason: GameEndReason?
    /// They offered a draw; Accept sends drawAccept.
    var drawOffered = false
    var privateData = Data()
    var lastNak: GameNakReason?
    var outOfSync = false

    /// Committed moves.
    var seq: Int { moves.count / kind.moveSize }

    init(id: UInt32, kind: GameKind, peer: Int64, me: Player, options: Data, phase: GamePhase) {
        self.id = id; self.kind = kind; self.peer = peer; self.me = me
        self.options = options; self.phase = phase
    }

    func engine() -> any GameEngine {
        (try? kind.replay(options: options, moves: moves)) ?? kind.make(options: options)
    }

    /// Hash after the first `count` committed moves.
    func hash(after count: Int) -> UInt32 {
        let prefix = moves.prefix(count * kind.moveSize)
        let engine = (try? kind.replay(options: options, moves: Data(prefix))) ?? kind.make(options: options)
        return StateHash.of(engine)
    }

    var currentHash: UInt32 { hash(after: seq) }

    /// Hash after the pending move is applied on top of the committed log.
    func hashWithPending() -> UInt32? {
        guard let pending else { return nil }
        var engine = engine()
        guard (try? engine.apply(pending)) != nil else { return nil }
        return StateHash.of(engine)
    }

    var isActive: Bool { [.myTurn, .waiting, .theirTurn].contains(phase) }

    /// Who played the last committed move (by replaying up to it).
    var lastMoveWasTheirs: Bool {
        guard seq > 0 else { return false }
        let prefix = Data(moves.prefix((seq - 1) * kind.moveSize))
        let before = (try? kind.replay(options: options, moves: prefix)) ?? kind.make(options: options)
        return before.toMove == me.other
    }

    /// Player whose turn it is, per the engine — decides turn after commits.
    mutating func settleTurn() {
        let engine = engine()
        if let r = engine.result {
            result = r
            phase = .finished
        } else {
            phase = engine.toMove == me ? .myTurn : .theirTurn
        }
    }
}

enum GameFrame: Equatable {
    case invite(session: UInt32, kind: GameKind, options: Data)
    case accept(session: UInt32)
    case decline(session: UInt32)
    case move(session: UInt32, seq: UInt16, prevHash: UInt32, move: Data)
    case ack(session: UInt32, seq: UInt16, stateHash: UInt32)
    case nak(session: UInt32, seq: UInt16, reason: GameNakReason)
    case resync(session: UInt32, fromSeq: UInt16)
    case sync(session: UInt32, fromSeq: UInt16, moves: Data)
    case end(session: UInt32, reason: GameEndReason)

    static let version: UInt8 = 1

    var session: UInt32 {
        switch self {
        case .invite(let s, _, _), .accept(let s), .decline(let s), .move(let s, _, _, _),
             .ack(let s, _, _), .nak(let s, _, _), .resync(let s, _), .sync(let s, _, _), .end(let s, _):
            return s
        }
    }

    func encoded() -> Data {
        var d = Data()
        switch self {
        case .invite(let s, let kind, let options):
            d.append(0x01); d.append(Self.version); d.appendUInt32(s); d.append(kind.rawValue); d.append(options)
        case .accept(let s): d.append(0x02); d.appendUInt32(s)
        case .decline(let s): d.append(0x03); d.appendUInt32(s)
        case .move(let s, let seq, let prev, let move):
            d.append(0x04); d.appendUInt32(s); d.appendUInt16(seq); d.appendUInt32(prev); d.append(move)
        case .ack(let s, let seq, let hash):
            d.append(0x05); d.appendUInt32(s); d.appendUInt16(seq); d.appendUInt32(hash)
        case .nak(let s, let seq, let reason):
            d.append(0x06); d.appendUInt32(s); d.appendUInt16(seq); d.append(reason.rawValue)
        case .resync(let s, let from): d.append(0x07); d.appendUInt32(s); d.appendUInt16(from)
        case .sync(let s, let from, let moves):
            d.append(0x08); d.appendUInt32(s); d.appendUInt16(from); d.append(moves)
        case .end(let s, let reason): d.append(0x09); d.appendUInt32(s); d.append(reason.rawValue)
        }
        return d
    }

    init?(_ data: Data) {
        let bytes = Data(data)   // zero-based indexing
        guard let type = bytes.first else { return nil }
        switch type {
        case 0x01:
            guard bytes.count >= 7, let s = bytes.uint32(at: 2), let kind = GameKind(rawValue: bytes[6]) else { return nil }
            self = .invite(session: s, kind: kind, options: Data(bytes.dropFirst(7)))
        case 0x02:
            guard let s = bytes.uint32(at: 1) else { return nil }
            self = .accept(session: s)
        case 0x03:
            guard let s = bytes.uint32(at: 1) else { return nil }
            self = .decline(session: s)
        case 0x04:
            guard let s = bytes.uint32(at: 1), let seq = bytes.uint16(at: 5), let prev = bytes.uint32(at: 7),
                  bytes.count > 11 else { return nil }
            self = .move(session: s, seq: seq, prevHash: prev, move: Data(bytes.dropFirst(11)))
        case 0x05:
            guard let s = bytes.uint32(at: 1), let seq = bytes.uint16(at: 5), let hash = bytes.uint32(at: 7) else { return nil }
            self = .ack(session: s, seq: seq, stateHash: hash)
        case 0x06:
            guard let s = bytes.uint32(at: 1), let seq = bytes.uint16(at: 5), bytes.count >= 8,
                  let reason = GameNakReason(rawValue: bytes[7]) else { return nil }
            self = .nak(session: s, seq: seq, reason: reason)
        case 0x07:
            guard let s = bytes.uint32(at: 1), let from = bytes.uint16(at: 5) else { return nil }
            self = .resync(session: s, fromSeq: from)
        case 0x08:
            guard let s = bytes.uint32(at: 1), let from = bytes.uint16(at: 5) else { return nil }
            self = .sync(session: s, fromSeq: from, moves: Data(bytes.dropFirst(7)))
        case 0x09:
            guard let s = bytes.uint32(at: 1), bytes.count >= 6, let reason = GameEndReason(rawValue: bytes[5]) else { return nil }
            self = .end(session: s, reason: reason)
        default:
            return nil
        }
    }

    var summary: String {
        switch self {
        case .invite(let s, let kind, _): return "INVITE \(kind.title) #\(String(format: "%08X", s))"
        case .accept(let s): return "ACCEPT #\(String(format: "%08X", s))"
        case .decline(let s): return "DECLINE #\(String(format: "%08X", s))"
        case .move(let s, let seq, _, _): return "MOVE \(seq) #\(String(format: "%08X", s))"
        case .ack(let s, let seq, _): return "ACK \(seq) #\(String(format: "%08X", s))"
        case .nak(let s, let seq, let reason): return "NAK \(seq) \(reason) #\(String(format: "%08X", s))"
        case .resync(let s, let from): return "RESYNC from \(from) #\(String(format: "%08X", s))"
        case .sync(let s, let from, let moves): return "SYNC from \(from) (\(moves.count) B) #\(String(format: "%08X", s))"
        case .end(let s, let reason): return "END \(reason) #\(String(format: "%08X", s))"
        }
    }
}

/// What happened, for notifications and UI.
enum GameEvent: Equatable {
    case invited
    case accepted
    case declined
    case yourTurn
    case moveAgreed
    case finished
    case drawOffered
    case rejected(GameNakReason)
}

enum GameLogic {
    /// Max moves per SYNC frame so the packet stays well under 200 bytes.
    static let syncBudgetBytes = 160

    // MARK: Outbound by the user

    static func inviteFrame(_ r: GameSessionRecord) -> GameFrame {
        .invite(session: r.id, kind: r.kind, options: r.options)
    }

    /// The user plays `move`. Returns nil if it's not legal right now.
    static func play(_ move: Data, in r: inout GameSessionRecord) -> GameFrame? {
        guard r.phase == .myTurn, r.result == nil else { return nil }
        var engine = r.engine()
        guard engine.toMove == r.me, (try? engine.apply(move)) != nil else { return nil }
        r.pending = move
        r.phase = .waiting
        r.lastNak = nil
        return moveFrame(r)
    }

    /// The MOVE frame for whatever is pending — identical bytes on every resend.
    static func moveFrame(_ r: GameSessionRecord) -> GameFrame? {
        guard let pending = r.pending else { return nil }
        return .move(session: r.id, seq: UInt16(r.seq + 1), prevHash: r.currentHash, move: pending)
    }

    /// Everything worth resending for this record (reconnect, nudge, timer).
    static func resendFrames(_ r: GameSessionRecord) -> [GameFrame] {
        switch r.phase {
        case .inviting: return [inviteFrame(r)]
        case .waiting: return moveFrame(r).map { [$0] } ?? []
        case .theirTurn where r.seq > 0 && r.lastMoveWasTheirs:
            // Our ACK of their last move may have been lost; re-acking costs
            // one packet and unblocks them.
            return [.ack(session: r.id, seq: UInt16(r.seq), stateHash: r.currentHash)]
        default: return []
        }
    }

    static func accept(_ r: inout GameSessionRecord) -> GameFrame? {
        guard r.phase == .invited else { return nil }
        r.settleTurn()
        return .accept(session: r.id)
    }

    static func decline(_ r: inout GameSessionRecord) -> GameFrame? {
        guard r.phase == .invited else { return nil }
        r.phase = .declined
        return .decline(session: r.id)
    }

    static func resign(_ r: inout GameSessionRecord) -> GameFrame? {
        guard r.isActive else { return nil }
        r.result = .win(r.me.other); r.endReason = .resign; r.phase = .finished; r.pending = nil
        return .end(session: r.id, reason: .resign)
    }

    static func offerDraw(_ r: GameSessionRecord) -> GameFrame? {
        guard r.isActive else { return nil }
        return .end(session: r.id, reason: .drawOffer)
    }

    static func acceptDraw(_ r: inout GameSessionRecord) -> GameFrame? {
        guard r.isActive, r.drawOffered else { return nil }
        r.result = .draw; r.endReason = .drawAccept; r.phase = .finished; r.pending = nil
        return .end(session: r.id, reason: .drawAccept)
    }

    // MARK: Inbound

    struct Outcome {
        var replies: [GameFrame] = []
        var events: [GameEvent] = []
        var changed = false
    }

    /// An INVITE for a session we don't have yet → a fresh `.invited` record.
    static func newInvitedRecord(from peer: Int64, frame: GameFrame) -> GameSessionRecord? {
        guard case .invite(let s, let kind, let options) = frame, let first = options.first else { return nil }
        // options[0]: which side the inviter plays. We are the other one.
        let inviterSide = first == 0 ? Player.one : .two
        return GameSessionRecord(id: s, kind: kind, peer: peer, me: inviterSide.other,
                                 options: options, phase: .invited)
    }

    static func handle(_ frame: GameFrame, record r: inout GameSessionRecord) -> Outcome {
        var out = Outcome()
        switch frame {
        case .invite:
            // Duplicate invite: re-answer whatever we already decided.
            switch r.phase {
            case .declined: out.replies = [.decline(session: r.id)]
            case .invited: break
            default: out.replies = [.accept(session: r.id)]
            }

        case .accept:
            if r.phase == .inviting {
                r.settleTurn(); out.changed = true
                out.events = [.accepted] + (r.phase == .myTurn ? [.yourTurn] : [])
            }

        case .decline:
            if r.phase == .inviting {
                r.phase = .declined; out.changed = true; out.events = [.declined]
            }

        case .move(_, let seq, let prevHash, let move):
            handleMove(seq: Int(seq), prevHash: prevHash, move: move, record: &r, out: &out)

        case .ack(_, let seq, let stateHash):
            guard r.phase == .waiting, Int(seq) == r.seq + 1, let pending = r.pending else { break }
            if r.hashWithPending() == stateHash {
                r.moves.append(pending); r.pending = nil
                r.settleTurn(); out.changed = true
                out.events = [.moveAgreed] + (r.phase == .finished ? [.finished] : [])
            } else {
                r.outOfSync = true; out.changed = true
                out.events = [.rejected(.wrongPrevHash)]
            }

        case .nak(_, let seq, let reason):
            guard r.phase == .waiting, Int(seq) == r.seq + 1 else { break }
            r.pending = nil; r.lastNak = reason
            if reason == .wrongPrevHash { r.outOfSync = true }
            r.phase = .myTurn; out.changed = true
            out.events = [.rejected(reason)]

        case .resync(_, let fromSeq):
            out.replies = syncFrames(r, from: Int(fromSeq))

        case .sync(_, let fromSeq, let moves):
            // Adopt moves we're missing, one at a time, each validated.
            var next = Int(fromSeq)
            var offset = 0
            let size = r.kind.moveSize
            while offset + size <= moves.count {
                let move = moves.subdata(in: (moves.startIndex + offset)..<(moves.startIndex + offset + size))
                if next == r.seq + 1 {
                    var engine = r.engine()
                    if (try? engine.apply(move)) != nil {
                        r.moves.append(move); r.pending = nil; out.changed = true
                    } else { break }
                }
                next += 1; offset += size
            }
            if out.changed {
                r.outOfSync = false
                r.settleTurn()
                out.replies = [.ack(session: r.id, seq: UInt16(r.seq), stateHash: r.currentHash)]
                if r.phase == .myTurn { out.events = [.yourTurn] }
                if r.phase == .finished { out.events = [.finished] }
            }

        case .end(_, let reason):
            switch reason {
            case .resign, .abandon:
                guard r.result == nil else { break }
                r.result = .win(r.me); r.endReason = reason; r.phase = .finished; r.pending = nil
                out.changed = true; out.events = [.finished]
            case .drawOffer:
                guard r.isActive, !r.drawOffered else { break }
                r.drawOffered = true; out.changed = true; out.events = [.drawOffered]
            case .drawAccept:
                guard r.isActive else { break }
                r.result = .draw; r.endReason = .drawAccept; r.phase = .finished; r.pending = nil
                out.changed = true; out.events = [.finished]
            }
        }
        return out
    }

    private static func handleMove(seq: Int, prevHash: UInt32, move: Data,
                                   record r: inout GameSessionRecord, out: inout Outcome) {
        guard move.count == r.kind.moveSize else {
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .illegalMove)]; return
        }
        // An invite we never saw answered: their first move is the answer.
        if r.phase == .inviting { r.settleTurn(); out.changed = true; out.events.append(.accepted) }
        if r.phase == .invited { return }   // the human hasn't accepted yet
        if r.phase == .declined {
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .unknownSession)]; return
        }

        // Already have it: re-ack with the hash they need.
        if seq <= r.seq {
            out.replies = [.ack(session: r.id, seq: UInt16(seq), stateHash: r.hash(after: seq))]
            return
        }

        // Lost ACK for our pending move: their next move proves they applied
        // ours (its prevHash is our state-with-pending). Commit ours first.
        if r.phase == .waiting, seq == r.seq + 2, let pending = r.pending, r.hashWithPending() == prevHash {
            r.moves.append(pending); r.pending = nil; r.settleTurn(); out.changed = true
            out.events.append(.moveAgreed)
        }

        guard seq == r.seq + 1 else {
            out.replies = [.resync(session: r.id, fromSeq: UInt16(r.seq + 1))]
            return
        }
        guard r.currentHash == prevHash else {
            r.outOfSync = true; out.changed = true
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .wrongPrevHash)]
            return
        }
        var engine = r.engine()
        guard engine.result == nil else {
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .gameOver)]; return
        }
        guard engine.toMove == r.me.other else {
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .notYourTurn)]; return
        }
        guard (try? engine.apply(move)) != nil else {
            out.replies = [.nak(session: r.id, seq: UInt16(seq), reason: .illegalMove)]; return
        }
        r.moves.append(move); r.pending = nil; r.outOfSync = false
        r.settleTurn(); out.changed = true
        out.replies = [.ack(session: r.id, seq: UInt16(seq), stateHash: r.currentHash)]
        if r.phase == .myTurn { out.events.append(.yourTurn) }
        if r.phase == .finished { out.events.append(.finished) }
    }

    /// Moves from `from` (1-based seq) onward, packed into ≤ budget frames.
    static func syncFrames(_ r: GameSessionRecord, from: Int) -> [GameFrame] {
        guard from >= 1, from <= r.seq else { return [] }
        let size = r.kind.moveSize
        let perFrame = max(1, syncBudgetBytes / size)
        var frames: [GameFrame] = []
        var next = from
        while next <= r.seq {
            let count = min(perFrame, r.seq - next + 1)
            let start = (next - 1) * size
            let chunk = r.moves.subdata(in: (r.moves.startIndex + start)..<(r.moves.startIndex + start + count * size))
            frames.append(.sync(session: r.id, fromSeq: UInt16(next), moves: chunk))
            next += count
        }
        return frames
    }
}
