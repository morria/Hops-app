import Foundation
import SwiftData
import MeshtasticProtobufs

/// All radio-driven writes to the store go through this actor.
/// Views read via @Query; the radio layer never touches the main context.
@ModelActor
actor MessageStore {

    // MARK: - Node ingest

    func upsertNode(num: Int64) -> NodeEntity {
        if let existing = try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
        ).first {
            return existing
        }
        let node = NodeEntity(num: num)
        modelContext.insert(node)
        return node
    }

    /// Identity fields for building an outbound NodeInfo announcement.
    func nodeSnapshot(num: Int64) -> (longName: String, shortName: String, publicKey: Data, lastHeard: Date?)? {
        guard let node = try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
        ).first else { return nil }
        return (node.longName, node.shortName, node.publicKey, node.lastHeard)
    }

    /// Send-when-reachable: release messages held for a peer we just heard.
    func releaseWaitingForPeer(_ peerNum: Int64) -> [OutgoingRecord] {
        let waitingRaw = MessageStatus.waitingForPeer.rawValue
        let held = (try? modelContext.fetch(FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.toNum == peerNum && $0.statusRaw == waitingRaw }))) ?? []
        guard !held.isEmpty else { return [] }
        let publicKey = (try? modelContext.fetch(FetchDescriptor<NodeEntity>(
            predicate: #Predicate { $0.num == peerNum })).first)?.publicKey ?? Data()
        var records: [OutgoingRecord] = []
        for message in held.sorted(by: { $0.timestamp < $1.timestamp }) {
            message.status = .sending
            records.append(OutgoingRecord(packetId: message.packetId, toNum: message.toNum,
                                          channel: message.channel, text: message.text,
                                          isEmoji: message.isEmoji, replyId: message.replyId,
                                          peerPublicKey: publicKey))
        }
        try? modelContext.save()
        return records
    }

    /// "Send Now" override on a held message.
    func recordForceSend(packetId: Int64) -> OutgoingRecord? {
        guard let message = try? modelContext.fetch(FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.packetId == packetId })).first,
              message.status == .waitingForPeer else { return nil }
        message.status = .sending
        let peer = message.toNum
        let publicKey = (try? modelContext.fetch(FetchDescriptor<NodeEntity>(
            predicate: #Predicate { $0.num == peer })).first)?.publicKey ?? Data()
        try? modelContext.save()
        return OutgoingRecord(packetId: message.packetId, toNum: message.toNum,
                              channel: message.channel, text: message.text,
                              isEmoji: message.isEmoji, replyId: message.replyId,
                              peerPublicKey: publicKey)
    }

    /// Mirrors firmware NodeDB.updateFrom: every packet bumps liveness.
    func heard(num: Int64, snr: Float, hopStart: UInt32, hopLimit: UInt32, rxTime: UInt32) {
        guard num > 0 else { return }
        let node = upsertNode(num: num)
        node.lastHeard = rxTime > 0 ? Date(timeIntervalSince1970: TimeInterval(rxTime)) : Date()
        if snr != 0 { node.snr = snr }
        if hopStart > 0, hopStart >= hopLimit { node.hopsAway = Int(hopStart - hopLimit) }
        try? modelContext.save()
    }

    func applyNodeInfo(_ info: NodeInfo) {
        let num = Int64(info.num)
        guard num > 0 else { return }
        let node = upsertNode(num: num)
        if info.hasUser {
            applyUser(info.user, to: node)
        }
        if info.hasPosition {
            applyPosition(info.position, to: node)
        }
        if info.hasDeviceMetrics, info.deviceMetrics.hasBatteryLevel {
            node.batteryLevel = Int(info.deviceMetrics.batteryLevel)
        }
        if info.lastHeard > 0 {
            node.lastHeard = Date(timeIntervalSince1970: TimeInterval(info.lastHeard))
        }
        if info.hasHopsAway { node.hopsAway = Int(info.hopsAway) }
        if info.snr != 0 { node.snr = info.snr }
        // Keep DM conversation titles in sync with renamed nodes.
        let key = ConversationEntity.dmKey(num)
        if let convo = fetchConversation(key: key) {
            convo.title = node.displayName
        }
        try? modelContext.save()
    }

    private func applyUser(_ user: User, to node: NodeEntity) {
        if !user.longName.isEmpty { node.longName = user.longName }
        if !user.shortName.isEmpty { node.shortName = user.shortName }
        node.roleRaw = Int32(user.role.rawValue)
        if !user.publicKey.isEmpty {
            if node.publicKey.isEmpty {
                node.publicKey = user.publicKey  // first-use key policy
            } else if node.publicKey != user.publicKey {
                node.keyChanged = true           // pinned key differs — surface it
            }
        }
        if user.hasIsUnmessagable {
            node.unmessagable = user.isUnmessagable
        }
    }

    private func applyPosition(_ position: Position, to node: NodeEntity) {
        let lat = Double(position.latitudeI) * 1e-7
        let lon = Double(position.longitudeI) * 1e-7
        // Reject null island and the simulator default.
        guard lat != 0 || lon != 0 else { return }
        let moved = abs(node.latitude - lat) > 0.0002 || abs(node.longitude - lon) > 0.0002
        node.latitude = lat
        node.longitude = lon
        node.hasPosition = true
        node.precisionBits = Int32(position.precisionBits)
        // Trail sample on meaningful movement (~25 m), capped per node.
        if moved {
            modelContext.insert(PositionSampleEntity(nodeNum: node.num, latitude: lat,
                                                     longitude: lon, timestamp: Date()))
        }
    }

    /// Retention: remove nodes unheard for the configured window. Nodes the user
    /// invested in — renamed, given a photo, or holding a conversation — survive.
    func pruneStaleNodes(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let stale = (try? modelContext.fetch(FetchDescriptor<NodeEntity>(
            predicate: #Predicate { $0.lastHeard == nil || $0.lastHeard! < cutoff }))) ?? []
        guard !stale.isEmpty else { return }
        let convoKeys = Set(((try? modelContext.fetch(FetchDescriptor<ConversationEntity>())) ?? []).map(\.key))
        var removedNums: [Int64] = []
        for node in stale {
            guard node.customName.isEmpty, node.iconData == nil,
                  !convoKeys.contains(ConversationEntity.dmKey(node.num)) else { continue }
            removedNums.append(node.num)
            modelContext.delete(node)
        }
        if !removedNums.isEmpty {
            let nums = Set(removedNums)
            let samples = (try? modelContext.fetch(FetchDescriptor<PositionSampleEntity>(
                predicate: #Predicate { nums.contains($0.nodeNum) }))) ?? []
            for sample in samples { modelContext.delete(sample) }
        }
        try? modelContext.save()
    }

    /// Trim trail samples: older than 24 h, or beyond 200 per node.
    func pruneTrails() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let old = (try? modelContext.fetch(FetchDescriptor<PositionSampleEntity>(
            predicate: #Predicate { $0.timestamp < cutoff }))) ?? []
        for sample in old { modelContext.delete(sample) }
        let all = (try? modelContext.fetch(FetchDescriptor<PositionSampleEntity>())) ?? []
        for (_, group) in Dictionary(grouping: all, by: { $0.nodeNum }) where group.count > 200 {
            for sample in group.sorted(by: { $0.timestamp < $1.timestamp }).dropLast(200) {
                modelContext.delete(sample)
            }
        }
        try? modelContext.save()
    }

    func applyPositionPacket(_ position: Position, from num: Int64) {
        let node = upsertNode(num: num)
        applyPosition(position, to: node)
        try? modelContext.save()
    }

    func applyTelemetry(_ telemetry: Telemetry, from num: Int64) {
        switch telemetry.variant {
        case .deviceMetrics(let metrics):
            guard metrics.hasBatteryLevel else { return }
            let node = upsertNode(num: num)
            node.batteryLevel = Int(metrics.batteryLevel)
        case .environmentMetrics(let metrics):
            let node = upsertNode(num: num)
            if metrics.hasTemperature { node.temperature = metrics.temperature }
            if metrics.hasRelativeHumidity { node.humidity = metrics.relativeHumidity }
            if metrics.hasBarometricPressure { node.pressure = metrics.barometricPressure }
            node.envUpdatedAt = Date()
        default:
            return
        }
        try? modelContext.save()
    }

    /// Store & Forward history replay: replays carry fresh packet ids and replay-time
    /// timestamps, so dedup is content-based — same sender + same text within the
    /// recovery horizon means we already have it.
    func ingestStoreForwardText(from senderNum: Int64, text: String, isBroadcast: Bool,
                                channel: Int32, myNum: Int64) -> InboundMessage? {
        guard !text.isEmpty, senderNum != myNum else { return nil }
        let horizon = Date().addingTimeInterval(-48 * 60 * 60)
        let existing = (try? modelContext.fetch(FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.fromNum == senderNum && $0.text == text && $0.timestamp > horizon }
        ))) ?? []
        guard existing.isEmpty else { return nil }

        var packet = MeshPacket()
        packet.id = UInt32.random(in: 0x100..<UInt32.max)
        packet.from = UInt32(truncatingIfNeeded: senderNum)
        packet.to = isBroadcast ? UInt32.max : UInt32(truncatingIfNeeded: myNum)
        packet.channel = UInt32(channel)
        var decoded = DataMessage()
        decoded.portnum = .textMessageApp
        decoded.payload = text.data(using: .utf8) ?? Data()
        packet.decoded = decoded
        return ingestTextMessage(packet: packet, myNum: myNum)
    }

    // MARK: - Channel ingest

    func applyChannel(_ channel: Channel) {
        let index = Int32(channel.index)
        let entity: ChannelEntity
        if let existing = try? modelContext.fetch(
            FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
        ).first {
            entity = existing
        } else {
            entity = ChannelEntity(index: index, name: "", roleRaw: 0, psk: Data())
            modelContext.insert(entity)
        }
        entity.name = channel.settings.name
        entity.roleRaw = Int32(channel.role.rawValue)
        entity.psk = channel.settings.psk

        // Active, non-reserved channels get a conversation row eagerly.
        let key = ConversationEntity.channelKey(index)
        if entity.isActive {
            if fetchConversation(key: key) == nil {
                let convo = ConversationEntity(key: key, kind: .channel, channelIndex: index, peerNum: 0, title: entity.displayName)
                modelContext.insert(convo)
            } else {
                fetchConversation(key: key)?.title = entity.displayName
            }
        } else if let convo = fetchConversation(key: key), convo.lastMessageAt == nil {
            modelContext.delete(convo)
        }
        try? modelContext.save()
    }

    /// Give the (blank-named) primary channel a friendly local name from the
    /// applied metro preset — e.g. "NYC Mesh". Never overrides a mesh-set name
    /// or one the user chose.
    func setPrimaryChannelName(ifUnnamed name: String) {
        let zero: Int32 = 0
        guard let entity = try? modelContext.fetch(
            FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == zero })
        ).first, entity.customName.isEmpty, entity.name.isEmpty else { return }
        entity.customName = name
        if let convo = fetchConversation(key: ConversationEntity.channelKey(0)) {
            convo.title = entity.displayName
        }
        try? modelContext.save()
    }

    func activeChannelIndices() -> [Int32] {
        let channels = (try? modelContext.fetch(FetchDescriptor<ChannelEntity>())) ?? []
        return channels.filter { $0.isActive }.map { $0.index }
    }

    // MARK: - Conversations

    func fetchConversationTitle(key: String) -> String? {
        fetchConversation(key: key)?.title
    }

    func fetchConversation(key: String) -> ConversationEntity? {
        try? modelContext.fetch(
            FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.key == key })
        ).first
    }

    func ensureConversation(key: String, kind: ConversationKind, channelIndex: Int32, peerNum: Int64, title: String) -> ConversationEntity {
        if let existing = fetchConversation(key: key) { return existing }
        let convo = ConversationEntity(key: key, kind: kind, channelIndex: channelIndex, peerNum: peerNum, title: title)
        modelContext.insert(convo)
        return convo
    }

    // MARK: - Message ingest

    struct InboundMessage: Sendable {
        var conversationKey: String
        var conversationTitle: String
        var senderNum: Int64
        var senderName: String
        var text: String
        var isDM: Bool
        var notifyLevelRaw: Int
        var isMention: Bool
        var packetId: Int64
        var isTapback: Bool
    }

    /// Returns a summary for notification purposes, or nil if deduplicated/self-echo.
    func ingestTextMessage(packet: MeshPacket, myNum: Int64) -> InboundMessage? {
        let packetId = Int64(packet.id)
        // Dedupe: the radio echoes our own sends back, and reconnect drains can overlap.
        if let existing = try? modelContext.fetch(
            FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.packetId == packetId })
        ).first {
            existing.read = existing.read || existing.outgoing
            return nil
        }
        guard let text = String(data: packet.decoded.payload, encoding: .utf8), !text.isEmpty else { return nil }

        let fromNum = Int64(packet.from)
        let toNum = Int64(packet.to)
        let outgoing = fromNum == myNum
        let isBroadcast = packet.to == UInt32.max
        let isDM = !isBroadcast

        let key: String
        let convo: ConversationEntity
        if isDM {
            let peer = outgoing ? toNum : fromNum
            let peerNode = upsertNode(num: peer)
            key = ConversationEntity.dmKey(peer)
            convo = ensureConversation(key: key, kind: .directMessage, channelIndex: 0, peerNum: peer, title: peerNode.displayName)
        } else {
            let index = Int32(packet.channel)
            key = ConversationEntity.channelKey(index)
            convo = ensureConversation(key: key, kind: .channel, channelIndex: index, peerNum: 0, title: "Channel \(index)")
        }

        let isTapback = packet.decoded.emoji != 0
        let message = MessageEntity(
            packetId: packetId,
            conversationKey: key,
            fromNum: fromNum,
            toNum: toNum,
            channel: Int32(packet.channel),
            text: text,
            timestamp: packet.rxTime > 0 ? Date(timeIntervalSince1970: TimeInterval(packet.rxTime)) : Date(),
            outgoing: outgoing,
            status: outgoing ? .sending : .received,
            isEmoji: isTapback,
            replyId: Int64(packet.decoded.replyID),
            portNum: Int32(packet.decoded.portnum.rawValue)
        )
        modelContext.insert(message)

        if !isTapback {
            convo.lastMessageAt = message.timestamp
            convo.lastPreview = text
        }
        if !outgoing && !isTapback {
            convo.unreadCount += 1
        }
        try? modelContext.save()

        guard !outgoing else { return nil }
        let sender = upsertNode(num: fromNum)
        // Mention: "@" + our short or long name, case-insensitive. Heuristic — the
        // protocol has no mention entity — used only to raise, never suppress.
        var isMention = false
        if let me = try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == myNum })
        ).first {
            let lowered = text.lowercased()
            for name in [me.shortName, me.longName] where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                if lowered.contains("@" + name.lowercased()) { isMention = true; break }
            }
        }
        return InboundMessage(
            conversationKey: key,
            conversationTitle: convo.title,
            senderNum: fromNum,
            senderName: sender.displayName,
            text: text,
            isDM: isDM,
            notifyLevelRaw: convo.notifyLevelRaw == 0 && convo.muted
                ? NotifyLevel.muted.rawValue : convo.notifyLevelRaw,
            isMention: isMention,
            packetId: packetId,
            isTapback: isTapback
        )
    }

    // MARK: - Delivery state

    /// Routing ack/nak handling: correlate on requestID.
    func applyRoutingResult(requestId: UInt32, errorRaw: Int32, ackFrom: Int64, ackTo: Int64) {
        let packetId = Int64(requestId)
        guard let message = try? modelContext.fetch(
            FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.packetId == packetId })
        ).first, message.outgoing else { return }

        if errorRaw != 0 {
            message.status = .failed
            message.ackErrorRaw = errorRaw
        } else if message.toNum == Int64(UInt32.max) {
            message.status = .sentToMesh
        } else if ackFrom == message.toNum && ackFrom != ackTo {
            // Explicit ack from the actual recipient, not our own radio's implicit ack.
            message.status = .deliveredToRadio
        } else if message.status != .deliveredToRadio {
            message.status = .relayed
        }
        try? modelContext.save()
    }

    /// Timeout fallback, evaluated on wake/foreground — never a live wall-clock promise.
    func sweepStaleSending(olderThan interval: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-interval)
        let sendingRaw = MessageStatus.sending.rawValue
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.statusRaw == sendingRaw && $0.timestamp < cutoff }
        )
        for message in (try? modelContext.fetch(descriptor)) ?? [] {
            message.status = .failed
            message.ackErrorRaw = -1  // local timeout, not a firmware NAK
        }
        try? modelContext.save()
    }

    // MARK: - Outgoing

    struct OutgoingRecord: Sendable {
        var packetId: Int64
        var toNum: Int64
        var channel: Int32
        var text: String
        var isEmoji: Bool
        var replyId: Int64
        var peerPublicKey: Data
    }

    func persistOutgoing(packetId: Int64, myNum: Int64, destination: MessageDestinationRef,
                         text: String, isEmoji: Bool, replyId: Int64, connected: Bool,
                         holdForPeer: Bool = false) -> OutgoingRecord {
        let key: String
        let toNum: Int64
        let channel: Int32
        var publicKey = Data()
        let convo: ConversationEntity
        switch destination {
        case .channel(let index):
            key = ConversationEntity.channelKey(index)
            toNum = Int64(UInt32.max)
            channel = index
            convo = ensureConversation(key: key, kind: .channel, channelIndex: index, peerNum: 0, title: "Channel \(index)")
        case .node(let num):
            key = ConversationEntity.dmKey(num)
            toNum = num
            channel = 0
            let node = upsertNode(num: num)
            publicKey = node.publicKey
            convo = ensureConversation(key: key, kind: .directMessage, channelIndex: 0, peerNum: num, title: node.displayName)
        }
        let message = MessageEntity(
            packetId: packetId,
            conversationKey: key,
            fromNum: myNum,
            toNum: toNum,
            channel: channel,
            text: text,
            timestamp: Date(),
            outgoing: true,
            status: !connected ? .waitingForRadio : (holdForPeer ? .waitingForPeer : .sending),
            isEmoji: isEmoji,
            replyId: replyId
        )
        modelContext.insert(message)
        // Stamp the conversation we hold directly — a re-fetch can miss a row
        // inserted in this same transaction, stranding a new thread off the list.
        if !isEmoji {
            convo.lastMessageAt = message.timestamp
            convo.lastPreview = text
        }
        try? modelContext.save()
        return OutgoingRecord(packetId: packetId, toNum: toNum, channel: channel,
                              text: text, isEmoji: isEmoji, replyId: replyId, peerPublicKey: publicKey)
    }

    /// Everything waiting in the outbox, oldest first; marks them .sending.
    func drainOutbox() -> [OutgoingRecord] {
        let waitingRaw = MessageStatus.waitingForRadio.rawValue
        var descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.statusRaw == waitingRaw }
        )
        descriptor.sortBy = [SortDescriptor(\.timestamp)]
        let waiting = (try? modelContext.fetch(descriptor)) ?? []
        var records: [OutgoingRecord] = []
        for message in waiting {
            message.status = .sending
            message.timestamp = Date()
            var publicKey = Data()
            if message.toNum != Int64(UInt32.max) {
                publicKey = upsertNode(num: message.toNum).publicKey
            }
            records.append(OutgoingRecord(packetId: message.packetId, toNum: message.toNum,
                                          channel: message.channel, text: message.text,
                                          isEmoji: message.isEmoji, replyId: message.replyId,
                                          peerPublicKey: publicKey))
        }
        try? modelContext.save()
        return records
    }

    /// Retry mints a fresh packet id — the mesh dedupes recent ids, so reuse would be
    /// silently swallowed. A duplicate at the recipient is the accepted tradeoff.
    func prepareRetry(packetId: Int64, newPacketId: Int64, connected: Bool) -> OutgoingRecord? {
        guard let message = try? modelContext.fetch(
            FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.packetId == packetId })
        ).first, message.outgoing else { return nil }
        message.packetId = newPacketId
        message.status = connected ? .sending : .waitingForRadio
        message.ackErrorRaw = 0
        message.timestamp = Date()
        var publicKey = Data()
        if message.toNum != Int64(UInt32.max) {
            publicKey = upsertNode(num: message.toNum).publicKey
        }
        try? modelContext.save()
        guard connected else { return nil }
        return OutgoingRecord(packetId: newPacketId, toNum: message.toNum, channel: message.channel,
                              text: message.text, isEmoji: message.isEmoji, replyId: message.replyId,
                              peerPublicKey: publicKey)
    }

    // MARK: - Waypoints

    func applyWaypoint(_ waypoint: Waypoint, from num: Int64) {
        let lat = Double(waypoint.latitudeI) * 1e-7
        let lon = Double(waypoint.longitudeI) * 1e-7
        guard lat != 0 || lon != 0 else { return }
        let waypointId = Int64(waypoint.id)
        let entity: WaypointEntity
        if let existing = try? modelContext.fetch(
            FetchDescriptor<WaypointEntity>(predicate: #Predicate { $0.waypointId == waypointId })
        ).first {
            entity = existing
        } else {
            let icon = waypoint.icon > 0 ? String(UnicodeScalar(waypoint.icon) ?? "📍") : "📍"
            entity = WaypointEntity(waypointId: waypointId, name: waypoint.name, icon: icon,
                                    latitude: lat, longitude: lon, expires: nil, createdBy: num)
            modelContext.insert(entity)
        }
        entity.name = waypoint.name
        entity.latitude = lat
        entity.longitude = lon
        entity.expires = waypoint.expire > 0 ? Date(timeIntervalSince1970: TimeInterval(waypoint.expire)) : nil
        try? modelContext.save()
    }

    // MARK: - Repair

    /// Backfill conversations stranded without a lastMessageAt (e.g. a single failed
    /// send from before the direct-stamp fix). Cheap; run once per launch.
    func repairConversations() {
        dedupeAfterSync()
        // Backfill legacy boolean mutes into the notify-level field.
        let mutedDescriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.muted == true && $0.notifyLevelRaw == 0 }
        )
        for convo in (try? modelContext.fetch(mutedDescriptor)) ?? [] {
            convo.notifyLevelRaw = NotifyLevel.muted.rawValue
        }
        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.lastMessageAt == nil }
        )
        for convo in (try? modelContext.fetch(descriptor)) ?? [] {
            let key = convo.key
            var messageDescriptor = FetchDescriptor<MessageEntity>(
                predicate: #Predicate { $0.conversationKey == key && $0.isEmoji == false }
            )
            messageDescriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
            messageDescriptor.fetchLimit = 1
            if let latest = ((try? modelContext.fetch(messageDescriptor)) ?? []).first {
                convo.lastMessageAt = latest.timestamp
                convo.lastPreview = latest.text
            }
        }
        try? modelContext.save()
    }

    /// CloudKit can't enforce unique keys, so two devices may each create a row
    /// for the same logical entity before sync merges. Collapse duplicates,
    /// keeping the richest copy.
    private func dedupeAfterSync() {
        // Conversations by key.
        let convos = (try? modelContext.fetch(FetchDescriptor<ConversationEntity>())) ?? []
        for (_, group) in Dictionary(grouping: convos, by: { $0.key }) where group.count > 1 {
            let keeper = group.max(by: { ($0.lastMessageAt ?? .distantPast) < ($1.lastMessageAt ?? .distantPast) })!
            for other in group where other !== keeper {
                keeper.pinned = keeper.pinned || other.pinned
                if keeper.notifyLevelRaw == 0 { keeper.notifyLevelRaw = other.notifyLevelRaw }
                modelContext.delete(other)
            }
        }
        // Nodes by num.
        let nodes = (try? modelContext.fetch(FetchDescriptor<NodeEntity>())) ?? []
        for (_, group) in Dictionary(grouping: nodes, by: { $0.num }) where group.count > 1 {
            let keeper = group.max(by: { ($0.lastHeard ?? .distantPast) < ($1.lastHeard ?? .distantPast) })!
            for other in group where other !== keeper {
                if keeper.iconData == nil { keeper.iconData = other.iconData }
                if keeper.publicKey.isEmpty { keeper.publicKey = other.publicKey }
                modelContext.delete(other)
            }
        }
        // Channels by index, messages by packetId, waypoints by id.
        let channels = (try? modelContext.fetch(FetchDescriptor<ChannelEntity>())) ?? []
        for (_, group) in Dictionary(grouping: channels, by: { $0.index }) where group.count > 1 {
            let keeper = group.first(where: { $0.iconData != nil }) ?? group[0]
            for other in group where other !== keeper { modelContext.delete(other) }
        }
        let messages = (try? modelContext.fetch(FetchDescriptor<MessageEntity>())) ?? []
        for (_, group) in Dictionary(grouping: messages, by: { $0.packetId }) where group.count > 1 {
            let keeper = group.max(by: { $0.statusRaw < $1.statusRaw })!
            for other in group where other !== keeper { modelContext.delete(other) }
        }
        let waypoints = (try? modelContext.fetch(FetchDescriptor<WaypointEntity>())) ?? []
        for (_, group) in Dictionary(grouping: waypoints, by: { $0.waypointId }) where group.count > 1 {
            for other in group.dropFirst() { modelContext.delete(other) }
        }
        try? modelContext.save()
    }

    // MARK: - Read state

    func markConversationRead(key: String) {
        guard let convo = fetchConversation(key: key) else { return }
        convo.unreadCount = 0
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationKey == key && $0.read == false }
        )
        for message in (try? modelContext.fetch(descriptor)) ?? [] {
            message.read = true
        }
        try? modelContext.save()
    }

    func totalUnreadConversations() -> Int {
        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.unreadCount > 0 }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

/// Sendable destination reference used across actor boundaries.
enum MessageDestinationRef: Sendable, Hashable {
    case channel(Int32)
    case node(Int64)
}
