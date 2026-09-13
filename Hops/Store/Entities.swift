import Foundation
import SwiftData

// CloudKit-synced schema: no unique constraints (CloudKit forbids them — logical
// keys are deduplicated by fetch-before-insert plus the launch repair pass), and
// every stored property carries an inline default.

// MARK: - Conversation

enum ConversationKind: Int {
    case channel = 0
    case directMessage = 1
}

enum NotifyLevel: Int {
    case all = 0
    case mentionsOnly = 1
    case muted = 2
}

@Model
final class ConversationEntity {
    var key: String = ""        // "ch-<index>" or "dm-<nodeNum>"
    var kindRaw: Int = 0
    var channelIndex: Int32 = 0
    var peerNum: Int64 = 0
    var title: String = ""
    var lastMessageAt: Date?
    var lastPreview: String = ""
    /// Status mirror of the message backing lastPreview — only meaningful
    /// when lastMessagePacketId != 0 (i.e. that message was outgoing).
    var lastStatusRaw: Int = 0
    /// Reliability: our last sent sequence number in this conversation
    /// (mod 256; -1 = none sent yet). See docs/RELIABILITY.md.
    var seqCounter: Int = -1
    var lastMessagePacketId: Int64 = 0
    var unreadCount: Int = 0
    var pinned: Bool = false
    var muted: Bool = false                    // legacy; kept in sync with notifyLevel
    var notifyLevelRaw: Int = 0

    var kind: ConversationKind { ConversationKind(rawValue: kindRaw) ?? .channel }

    var notifyLevel: NotifyLevel {
        get { NotifyLevel(rawValue: notifyLevelRaw) ?? .all }
        set {
            notifyLevelRaw = newValue.rawValue
            muted = newValue == .muted
        }
    }

    init(key: String, kind: ConversationKind, channelIndex: Int32, peerNum: Int64, title: String) {
        self.key = key
        self.kindRaw = kind.rawValue
        self.channelIndex = channelIndex
        self.peerNum = peerNum
        self.title = title
    }

    static func channelKey(_ index: Int32) -> String { "ch-\(index)" }
    static func dmKey(_ num: Int64) -> String { "dm-\(num)" }
}

// MARK: - Message

/// Delivery/lifecycle state. Raw values are persisted — append only.
enum MessageStatus: Int {
    case received = 0          // inbound
    case waitingForRadio = 1   // outbox: composed with no radio link
    case sending = 2           // written to radio, awaiting ack
    case relayed = 3           // DM: mesh forwarded it, recipient not yet confirmed
    case deliveredToRadio = 4  // DM: recipient's radio acked
    case sentToMesh = 5        // channel broadcast: terminal success
    case failed = 6            // NAK or timeout
    case waitingForPeer = 7    // held until the recipient's radio is heard again
}

@Model
final class MessageEntity {
    var packetId: Int64 = 0
    var conversationKey: String = ""
    var fromNum: Int64 = 0
    var toNum: Int64 = 0
    var channel: Int32 = 0
    var text: String = ""
    var timestamp: Date = Date(timeIntervalSince1970: 0)
    var outgoing: Bool = false
    var statusRaw: Int = 0
    var ackErrorRaw: Int32 = 0 // Routing.Error raw value when failed
    var isEmoji: Bool = false  // tapback/reaction
    var replyId: Int64 = 0     // packet id this replies/reacts to (0 = none)
    var read: Bool = false
    var portNum: Int32 = 1
    /// Reliability sequence number (mod 256; -1 = none). Outgoing: assigned
    /// per conversation. Incoming: parsed from the Data bitfield.
    var seqNum: Int = -1
    /// Send-when-heard cycles this message has been through — a released
    /// hold that times out re-holds itself (capped) instead of failing.
    var heldRetryCount: Int = 0
    /// Which of the owner's radios sent or heard this (fleet, TODO 193).
    /// 0 = unknown (rows written before fleets existed).
    var viaNodeNum: Int64 = 0

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .received }
        set { statusRaw = newValue.rawValue }
    }

    init(packetId: Int64, conversationKey: String, fromNum: Int64, toNum: Int64,
         channel: Int32, text: String, timestamp: Date, outgoing: Bool,
         status: MessageStatus, isEmoji: Bool = false, replyId: Int64 = 0, portNum: Int32 = 1) {
        self.packetId = packetId
        self.conversationKey = conversationKey
        self.fromNum = fromNum
        self.toNum = toNum
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.outgoing = outgoing
        self.statusRaw = status.rawValue
        self.isEmoji = isEmoji
        self.replyId = replyId
        self.read = outgoing
        self.portNum = portNum
        // seqNum stays -1 unless the reliability layer assigns/parses one.
    }
}

// MARK: - Radio (one of the owner's radios — the fleet, docs/MULTI_RADIO.md)

@Model
final class RadioEntity {
    var nodeNum: Int64 = 0
    var publicKey: Data = Data()
    var nickname: String = ""
    /// "home" / "office" / "mobile" / "other" — drives role suggestions.
    var locationTag: String = "other"
    var hwModelRaw: Int32 = 0
    var firmware: String = ""
    var addedAt: Date = Date()
    var lastSeenAt: Date?
    var lastBattery: Int = -1
    /// Owner's sort order; lower = higher priority. The highest attached
    /// radio is the transmit radio.
    var priority: Int = 0

    init(nodeNum: Int64, nickname: String, priority: Int) {
        self.nodeNum = nodeNum
        self.nickname = nickname
        self.priority = priority
        self.addedAt = Date()
    }

    var displayName: String {
        nickname.isEmpty ? String(format: "Radio !%08x", UInt32(truncatingIfNeeded: nodeNum)) : nickname
    }
}

// MARK: - Node

@Model
final class NodeEntity {
    var num: Int64 = 0
    var longName: String = ""
    var shortName: String = ""
    var lastHeard: Date?
    var snr: Float = 0
    var hopsAway: Int = -1
    var hasPosition: Bool = false
    var latitude: Double = 0
    var longitude: Double = 0
    var precisionBits: Int32 = 0
    var batteryLevel: Int = -1 // -1 unknown, 101 = plugged in
    var roleRaw: Int32 = 0
    var publicKey: Data = Data()
    var unmessagable: Bool = false
    /// User-chosen avatar photo (device-set, synced via iCloud).
    @Attribute(.externalStorage) var iconData: Data?
    /// Local override name; empty = use the mesh-reported longName.
    var customName: String = ""
    /// PKI: a different key arrived after we pinned the first one.
    var keyChanged: Bool = false
    // Environment telemetry (sentinels = unknown).
    var temperature: Float = -1000     // °C
    var humidity: Float = -1           // %
    var pressure: Float = -1           // hPa
    var envUpdatedAt: Date?
    /// User chose to hide this node's readings from the Weather map.
    var weatherHidden: Bool = false

    /// What to show anywhere this node is named.
    var displayName: String { customName.isEmpty ? longName : customName }

    var hasRecentEnvironment: Bool {
        guard temperature > -999, let at = envUpdatedAt else { return false }
        return Date().timeIntervalSince(at) < 6 * 60 * 60
    }

    init(num: Int64) {
        self.num = num
        self.longName = "Node \(String(format: "%08x", UInt32(truncatingIfNeeded: num)))"
        self.shortName = String(format: "%04x", UInt32(truncatingIfNeeded: num) & 0xFFFF)
    }

    var isOnline: Bool {
        guard let heard = lastHeard else { return false }
        return Date().timeIntervalSince(heard) < 2 * 60 * 60
    }

    /// Roles that cannot answer a DM: router(2), repeater(4), tracker(5), sensor(6),
    /// TAK(7), client-hidden(8)? per protocol {2,4,5,6,7,10,11} plus explicit flag.
    var isMessageable: Bool {
        if unmessagable { return false }
        return ![2, 4, 5, 6, 7, 10, 11].contains(Int(roleRaw))
    }

    var monogram: String {
        let trimmed = shortName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(4))
    }
}

// MARK: - Channel

@Model
final class ChannelEntity {
    var index: Int32 = 0
    var name: String = ""
    var roleRaw: Int32 = 0     // 0 disabled, 1 primary, 2 secondary
    var psk: Data = Data()
    /// User-chosen avatar photo (device-set, synced via iCloud).
    @Attribute(.externalStorage) var iconData: Data?
    /// Local override name; empty = derive from the mesh channel name.
    var customName: String = ""

    init(index: Int32, name: String, roleRaw: Int32, psk: Data) {
        self.index = index
        self.name = name
        self.roleRaw = roleRaw
        self.psk = psk
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        if !name.isEmpty { return name }
        return roleRaw == 1 ? "Public" : "Channel \(index)"
    }

    static let reservedNames: Set<String> = ["admin", "gpio", "serial", "mqtt"]
    var isReserved: Bool { Self.reservedNames.contains(name.lowercased()) }
    var isActive: Bool { roleRaw != 0 && !isReserved }
}

// MARK: - Reliability sequence tracking

/// Receiver-side: the last sequence number seen per (conversation, sender).
/// CloudKit-safe: inline defaults, no unique constraints.
@Model
final class SeqTrackEntity {
    /// "<conversationKey>|<senderNum>"
    var key: String = ""
    var lastSeen: Int = -1
    init(key: String) { self.key = key }
}

// MARK: - Position samples (trails)

@Model
final class PositionSampleEntity {
    var nodeNum: Int64 = 0
    var latitude: Double = 0
    var longitude: Double = 0
    var timestamp: Date = Date(timeIntervalSince1970: 0)

    init(nodeNum: Int64, latitude: Double, longitude: Double, timestamp: Date) {
        self.nodeNum = nodeNum
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}

// MARK: - Coverage survey

/// Where we were and how well we heard the mesh there (best SNR in the window).
@Model
final class CoverageSampleEntity {
    var latitude: Double = 0
    var longitude: Double = 0
    var snr: Float = 0
    var packets: Int = 0
    var timestamp: Date = Date(timeIntervalSince1970: 0)

    init(latitude: Double, longitude: Double, snr: Float, packets: Int, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.snr = snr
        self.packets = packets
        self.timestamp = timestamp
    }
}

// MARK: - Waypoint

@Model
final class WaypointEntity {
    var waypointId: Int64 = 0
    var name: String = ""
    var icon: String = "📍"
    var latitude: Double = 0
    var longitude: Double = 0
    var expires: Date?
    var createdBy: Int64 = 0

    init(waypointId: Int64, name: String, icon: String, latitude: Double, longitude: Double, expires: Date?, createdBy: Int64) {
        self.waypointId = waypointId
        self.name = name
        self.icon = icon
        self.latitude = latitude
        self.longitude = longitude
        self.expires = expires
        self.createdBy = createdBy
    }
}

// MARK: - Game session (docs/GAMES.md §3) — one two-player game with a peer

@Model
final class GameSessionEntity {
    /// 32-bit session id chosen by the inviter; unique with `peerNum`.
    var sessionId: Int64 = 0
    var kindRaw: Int = 0
    var peerNum: Int64 = 0
    var myPlayerRaw: Int = 0
    var options: Data = Data()
    /// Committed moves, fixed width per game kind.
    var moves: Data = Data()
    var phaseRaw: String = "inviting"
    var pendingMove: Data?
    /// 0 none, 1 player one wins, 2 player two wins, 3 draw.
    var resultRaw: Int = 0
    var endReasonRaw: Int = 0
    var drawOffered: Bool = false
    /// Hidden local setup (Battleship placement). Never transmitted.
    var privateData: Data = Data()
    var lastNakRaw: Int = 0
    var outOfSync: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// When the frame in flight was last sent (resend backoff).
    var lastSentAt: Date?
    var sendAttempts: Int = 0
    var lastNudgeAt: Date?
    /// Which of my radios carried the last frame (fleet bookkeeping).
    var viaNodeNum: Int64 = 0
    /// Something new for the user: an invite, their turn, a result.
    var needsAttention: Bool = false

    init(record: GameSessionRecord) {
        sessionId = Int64(record.id)
        kindRaw = Int(record.kind.rawValue)
        peerNum = record.peer
        myPlayerRaw = Int(record.me.rawValue)
        options = record.options
        createdAt = Date()
        apply(record)
    }

    var kind: GameKind { GameKind(rawValue: UInt8(clamping: kindRaw)) ?? .ticTacToe }
    var myPlayer: Player { Player(rawValue: UInt8(clamping: myPlayerRaw)) ?? .one }
    var phase: GamePhase { GamePhase(rawValue: phaseRaw) ?? .inviting }

    var record: GameSessionRecord {
        var r = GameSessionRecord(id: UInt32(truncatingIfNeeded: sessionId), kind: kind, peer: peerNum,
                                  me: myPlayer, options: options, phase: phase)
        r.moves = moves
        r.pending = pendingMove
        switch resultRaw {
        case 1: r.result = .win(.one)
        case 2: r.result = .win(.two)
        case 3: r.result = .draw
        default: r.result = nil
        }
        r.endReason = GameEndReason(rawValue: UInt8(clamping: endReasonRaw))
        r.drawOffered = drawOffered
        r.privateData = privateData
        r.lastNak = GameNakReason(rawValue: UInt8(clamping: lastNakRaw))
        r.outOfSync = outOfSync
        return r
    }

    func apply(_ r: GameSessionRecord) {
        moves = r.moves
        phaseRaw = r.phase.rawValue
        pendingMove = r.pending
        switch r.result {
        case .win(.one)?: resultRaw = 1
        case .win(.two)?: resultRaw = 2
        case .draw?: resultRaw = 3
        case nil: resultRaw = 0
        }
        endReasonRaw = Int(r.endReason?.rawValue ?? 0)
        drawOffered = r.drawOffered
        privateData = r.privateData
        lastNakRaw = Int(r.lastNak?.rawValue ?? 0)
        outOfSync = r.outOfSync
        updatedAt = Date()
    }

    /// "You won", "Draw", nil while playing.
    var resultText: String? {
        switch resultRaw {
        case 3: return "Draw"
        case 1, 2:
            let winner: Player = resultRaw == 1 ? .one : .two
            let mine = winner == myPlayer
            switch GameEndReason(rawValue: UInt8(clamping: endReasonRaw)) {
            case .resign?: return mine ? "You won — they resigned" : "You resigned"
            case .abandon?: return mine ? "You won — they left" : "You left"
            default: return mine ? "You won" : "You lost"
            }
        default: return nil
        }
    }
}
