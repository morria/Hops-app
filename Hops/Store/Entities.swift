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
