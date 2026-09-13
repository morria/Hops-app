#if DEBUG
import Foundation
import SwiftData

/// Screenshot/dev support only: `-screenshots` skips the notification prompt and seeds
/// demo data; `-tab map|settings` preselects a tab. Never active in release builds.
enum ScreenshotMode {
    static var isActive: Bool { CommandLine.arguments.contains("-screenshots") }

    static var initialConversation: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-conversation"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static var initialTab: Int {
        guard let index = CommandLine.arguments.firstIndex(of: "-tab"),
              CommandLine.arguments.count > index + 1 else { return 0 }
        switch CommandLine.arguments[index + 1] {
        case "map": return 1
        case "settings": return 2
        case "games": return 4
        default: return 0
        }
    }

    /// `-game chess|checkers|…` opens a seeded mid-game session on launch.
    static var initialGame: GameKind? {
        guard let index = CommandLine.arguments.firstIndex(of: "-game"),
              CommandLine.arguments.count > index + 1 else { return nil }
        switch CommandLine.arguments[index + 1] {
        case "chess": return .chess
        case "checkers": return .checkers
        case "battleship": return .battleship
        case "connectfour": return .connectFour
        case "dots": return .dotsAndBoxes
        case "tictactoe": return .ticTacToe
        default: return nil
        }
    }

    @MainActor static var seededGameSessionId: Int64?

    /// Demo game sessions in every state the tab shows; returns the session
    /// id for `-game` so the app can open it.
    @MainActor
    static func seedGames(container: ModelContainer) -> Int64? {
        guard isActive, initialTab == 4 || initialGame != nil else { return nil }
        UserDefaults.standard.set(true, forKey: "gamesEnabled")
        let context = container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<GameSessionEntity>())) ?? 0) == 0 else {
            let wanted = initialGame ?? .chess
            return (try? context.fetch(FetchDescriptor<GameSessionEntity>()))?
                .first { $0.kind == wanted }?.sessionId
        }
        func make(_ kind: GameKind, peer: Int64, me: Player, phase: GamePhase, moves: [[UInt8]] = [],
                  pending: [UInt8]? = nil, attention: Bool = false, minutesAgo: Double = 5) -> GameSessionEntity {
            var r = GameSessionRecord(id: UInt32.random(in: 1...UInt32.max), kind: kind, peer: peer, me: me,
                                      options: Data([me == .one ? 0 : 1]), phase: phase)
            for m in moves { r.moves.append(contentsOf: m) }
            r.pending = pending.map { Data($0) }
            if [.finished, .myTurn, .theirTurn].contains(phase) { r.settleTurn() }
            let e = GameSessionEntity(record: r)
            e.needsAttention = attention
            e.updatedAt = Date().addingTimeInterval(-minutesAgo * 60)
            context.insert(e)
            return e
        }
        // Chess, mid-game (Italian opening), my move.
        func sq(_ n: String) -> UInt8 { UInt8((Int(n.unicodeScalars.first!.value) - 97) + (Int(String(n.last!))! - 1) * 8) }
        let chessMoves: [[UInt8]] = [["e2","e4"],["e7","e5"],["g1","f3"],["b8","c6"],["f1","c4"],["f8","c5"],
                                     ["c2","c3"],["g8","f6"],["d2","d4"],["e5","d4"]].map { [sq($0[0]), sq($0[1]), 0] }
        let chess = make(.chess, peer: 0xA1B2C3, me: .one, phase: .myTurn, moves: chessMoves, attention: true, minutesAgo: 12)
        _ = make(.checkers, peer: 0xC3D4E5, me: .two, phase: .invited, attention: true, minutesAgo: 30)
        // A few plies of whatever is legal, so boards have pieces off the start squares.
        func plies(_ kind: GameKind, _ count: Int) -> [[UInt8]] {
            var engine = kind.make(options: Data([0])); var out: [[UInt8]] = []
            for i in 0..<count {
                let legal = engine.legalMoves(); guard !legal.isEmpty else { break }
                let move = legal[(i * 5) % legal.count]
                guard (try? engine.apply(move)) != nil else { break }
                out.append([UInt8](move))
            }
            return out
        }
        _ = make(.checkers, peer: 0xB2C3D4, me: .one, phase: .theirTurn, moves: plies(.checkers, 7), minutesAgo: 45)
        _ = make(.battleship, peer: 0xC3D4E5, me: .one, phase: .myTurn, attention: true, minutesAgo: 8)
        _ = make(.dotsAndBoxes, peer: 0xA1B2C3, me: .two, phase: .theirTurn, moves: plies(.dotsAndBoxes, 9), minutesAgo: 120)
        _ = make(.connectFour, peer: 0xB2C3D4, me: .one, phase: .waiting, moves: [[3], [3], [4]], pending: [2], minutesAgo: 90)
        _ = make(.ticTacToe, peer: 0xA1B2C3, me: .two, phase: .finished,
                 moves: [[0], [4], [1], [8], [2]], minutesAgo: 60 * 26)
        try? context.save()
        let wanted = initialGame ?? .chess
        if wanted == .chess { return chess.sessionId }
        return (try? context.fetch(FetchDescriptor<GameSessionEntity>()))?.first { $0.kind == wanted }?.sessionId
    }

    @MainActor
    static func seedIfNeeded(container: ModelContainer) {
        guard isActive else { return }
        let context = container.mainContext
        let existing = (try? context.fetchCount(FetchDescriptor<ConversationEntity>())) ?? 0
        guard existing == 0 else { return }

        func node(_ num: Int64, _ long: String, _ short: String, minutesAgo: Double,
                  hops: Int, battery: Int, lat: Double? = nil, lon: Double? = nil, precision: Int32 = 32) -> NodeEntity {
            let n = NodeEntity(num: num)
            n.longName = long
            n.shortName = short
            n.lastHeard = Date().addingTimeInterval(-minutesAgo * 60)
            n.hopsAway = hops
            n.batteryLevel = battery
            n.snr = 8.25
            if let lat, let lon {
                n.hasPosition = true
                n.latitude = lat
                n.longitude = lon
                n.precisionBits = precision
            }
            context.insert(n)
            return n
        }

        _ = node(0xA1B2C3, "Sam Rivera", "SAMR", minutesAgo: 4, hops: 0, battery: 82, lat: 37.7793, lon: -122.4193)
        _ = node(0xB2C3D4, "Marina Overlook", "MRNA", minutesAgo: 18, hops: 1, battery: 101, lat: 37.8064, lon: -122.4331)
        _ = node(0xC3D4E5, "Kat (bike)", "KAT", minutesAgo: 55, hops: 2, battery: 47, lat: 37.7599, lon: -122.4270, precision: 14)
        _ = node(0xD4E5F6, "Twin Peaks Relay", "TPKS", minutesAgo: 200, hops: 1, battery: 101, lat: 37.7544, lon: -122.4477)

        let ch0 = ChannelEntity(index: 0, name: "BayMesh", roleRaw: 1, psk: Data([1]))
        let ch1 = ChannelEntity(index: 1, name: "Family", roleRaw: 2, psk: Data(repeating: 7, count: 16))
        context.insert(ch0)
        context.insert(ch1)

        let mesh = ConversationEntity(key: "ch-0", kind: .channel, channelIndex: 0, peerNum: 0, title: "BayMesh")
        let family = ConversationEntity(key: "ch-1", kind: .channel, channelIndex: 1, peerNum: 0, title: "Family")
        family.pinned = true
        let sam = ConversationEntity(key: "dm-\(0xA1B2C3)", kind: .directMessage, channelIndex: 0, peerNum: 0xA1B2C3, title: "Sam Rivera")
        let kat = ConversationEntity(key: "dm-\(0xC3D4E5)", kind: .directMessage, channelIndex: 0, peerNum: 0xC3D4E5, title: "Kat (bike)")
        kat.muted = true
        for convo in [mesh, family, sam, kat] { context.insert(convo) }

        var packetId: Int64 = 1000
        func message(_ convo: ConversationEntity, _ text: String, from: Int64, minutesAgo: Double,
                     outgoing: Bool, status: MessageStatus, replyId: Int64 = 0, isEmoji: Bool = false) -> MessageEntity {
            packetId += 1
            let m = MessageEntity(packetId: packetId, conversationKey: convo.key,
                                  fromNum: from, toNum: outgoing && convo.kind == .directMessage ? convo.peerNum : Int64(UInt32.max),
                                  channel: convo.channelIndex, text: text,
                                  timestamp: Date().addingTimeInterval(-minutesAgo * 60),
                                  outgoing: outgoing, status: status, isEmoji: isEmoji, replyId: replyId)
            context.insert(m)
            if !isEmoji {
                convo.lastMessageAt = m.timestamp
                convo.lastPreview = text
            }
            return m
        }

        _ = message(mesh, "Anyone getting good SNR from the Presidio side today?", from: 0xB2C3D4, minutesAgo: 95, outgoing: false, status: .received)
        _ = message(mesh, "Yes — solid copy from the overlook, 2 hops.", from: 0, minutesAgo: 90, outgoing: true, status: .sentToMesh)
        _ = message(mesh, "New solar node going up on Twin Peaks this weekend 🎉", from: 0xC3D4E5, minutesAgo: 12, outgoing: false, status: .received)
        mesh.unreadCount = 1

        let hike = message(sam, "Trailhead at 9 — bring the antenna?", from: 0xA1B2C3, minutesAgo: 40, outgoing: false, status: .received)
        _ = message(sam, "On my way, ETA 15. Yes to the antenna.", from: 0, minutesAgo: 35, outgoing: true, status: .deliveredToRadio)
        _ = message(sam, "👍", from: 0xA1B2C3, minutesAgo: 33, outgoing: false, status: .received, replyId: hike.packetId, isEmoji: true)
        _ = message(sam, "Meet at the bench by the overlook instead", from: 0, minutesAgo: 3, outgoing: true, status: .relayed)
        sam.unreadCount = 0

        _ = message(family, "We're at the campsite, radio on all evening", from: 0xC3D4E5, minutesAgo: 500, outgoing: false, status: .received)
        _ = message(family, "Copy that — check in at 8?", from: 0, minutesAgo: 490, outgoing: true, status: .sentToMesh)

        _ = message(kat, "Heading up the coast, will be out of range til Sunday", from: 0xC3D4E5, minutesAgo: 2000, outgoing: false, status: .received)

        let waypoint = WaypointEntity(waypointId: 5001, name: "Camp", icon: "⛺️",
                                      latitude: 37.7684, longitude: -122.4530, expires: nil, createdBy: 0xC3D4E5)
        context.insert(waypoint)

        try? context.save()
    }
}
#endif
