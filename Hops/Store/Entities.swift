import Foundation
import SwiftData

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
    @Attribute(.unique) var key: String        // "ch-<index>" or "dm-<nodeNum>"
    var kindRaw: Int
    var channelIndex: Int32
    var peerNum: Int64
    var title: String
    var lastMessageAt: Date?
    var lastPreview: String
    var unreadCount: Int
    var pinned: Bool
    var muted: Bool                            // legacy; kept in sync with notifyLevel
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
        self.lastMessageAt = nil
        self.lastPreview = ""
        self.unreadCount = 0
        self.pinned = false
        self.muted = false
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
}

@Model
final class MessageEntity {
    @Attribute(.unique) var packetId: Int64
    var conversationKey: String
    var fromNum: Int64
    var toNum: Int64
    var channel: Int32
    var text: String
    var timestamp: Date
    var outgoing: Bool
    var statusRaw: Int
    var ackErrorRaw: Int32     // Routing.Error raw value when failed
    var isEmoji: Bool          // tapback/reaction
    var replyId: Int64         // packet id this replies/reacts to (0 = none)
    var read: Bool
    var portNum: Int32

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
        self.ackErrorRaw = 0
        self.isEmoji = isEmoji
        self.replyId = replyId
        self.read = outgoing
        self.portNum = portNum
    }
}

// MARK: - Node

@Model
final class NodeEntity {
    @Attribute(.unique) var num: Int64
    var longName: String
    var shortName: String
    var lastHeard: Date?
    var snr: Float
    var hopsAway: Int
    var hasPosition: Bool
    var latitude: Double
    var longitude: Double
    var precisionBits: Int32
    var batteryLevel: Int      // -1 unknown, 101 = plugged in
    var roleRaw: Int32
    var publicKey: Data
    var unmessagable: Bool

    init(num: Int64) {
        self.num = num
        self.longName = "Node \(String(format: "%08x", UInt32(truncatingIfNeeded: num)))"
        self.shortName = String(format: "%04x", UInt32(truncatingIfNeeded: num) & 0xFFFF)
        self.lastHeard = nil
        self.snr = 0
        self.hopsAway = -1
        self.hasPosition = false
        self.latitude = 0
        self.longitude = 0
        self.precisionBits = 0
        self.batteryLevel = -1
        self.roleRaw = 0
        self.publicKey = Data()
        self.unmessagable = false
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
    @Attribute(.unique) var index: Int32
    var name: String
    var roleRaw: Int32          // 0 disabled, 1 primary, 2 secondary
    var psk: Data

    init(index: Int32, name: String, roleRaw: Int32, psk: Data) {
        self.index = index
        self.name = name
        self.roleRaw = roleRaw
        self.psk = psk
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return roleRaw == 1 ? "Primary Channel" : "Channel \(index)"
    }

    static let reservedNames: Set<String> = ["admin", "gpio", "serial", "mqtt"]
    var isReserved: Bool { Self.reservedNames.contains(name.lowercased()) }
    var isActive: Bool { roleRaw != 0 && !isReserved }
}

// MARK: - Waypoint

@Model
final class WaypointEntity {
    @Attribute(.unique) var waypointId: Int64
    var name: String
    var icon: String
    var latitude: Double
    var longitude: Double
    var expires: Date?
    var createdBy: Int64

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
