import SwiftUI
import SwiftData
import CoreLocation
import MapKit

struct ConversationView: View {
    let conversationKey: String

    @EnvironmentObject private var radio: RadioManager
    @Environment(\.modelContext) private var modelContext

    @Query private var messages: [MessageEntity]
    @Query private var conversations: [ConversationEntity]

    @State private var draft = ""
    @State private var replyTarget: MessageEntity?
    @State private var reactionTarget: MessageEntity?
    @State private var reactionDetails: MessageEntity?   // message whose reactions to list
    @State private var senderCard: Int64?                // node card for a tapped sender
    @State private var showPeerCard = false
    @EnvironmentObject private var appModel: AppModel

    private static let byteLimit = 200

    init(conversationKey: String) {
        self.conversationKey = conversationKey
        let key = conversationKey
        _messages = Query(
            filter: #Predicate<MessageEntity> { $0.conversationKey == key },
            sort: \MessageEntity.timestamp
        )
        _conversations = Query(filter: #Predicate<ConversationEntity> { $0.key == key })
    }

    private var conversation: ConversationEntity? { conversations.first }
    private var isDM: Bool { conversationKey.hasPrefix("dm-") }

    /// Derived from the key, not the stored conversation — a brand-new thread has no
    /// ConversationEntity until the first message persists, and send must still work.
    private var destination: MessageDestinationRef? {
        if conversationKey.hasPrefix("ch-"), let index = Int32(conversationKey.dropFirst(3)) {
            return .channel(index)
        }
        if conversationKey.hasPrefix("dm-"), let num = Int64(conversationKey.dropFirst(3)) {
            return .node(num)
        }
        return nil
    }

    private var peerSecurity: (hasKey: Bool, keyChanged: Bool)? {
        guard case .node(let num) = destination,
              let node = try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
              ).first else { return nil }
        return (!node.publicKey.isEmpty, node.keyChanged)
    }

    private var peerMonogram: String {
        if case .node(let num) = destination {
            let node = try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first
            if let node { return node.monogram }
        }
        return "#"
    }

    /// Custom photo for the title bar: the peer node's (DM) or the channel's.
    private var peerIconData: Data? {
        switch destination {
        case .node(let num):
            return (try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first)?.iconData
        case .channel(let index):
            return (try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first)?.iconData
        case .none:
            return nil
        }
    }

    private var title: String {
        if let convo = conversation { return convo.title }
        if case .node(let num) = destination {
            let node = try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first
            if let node { return node.displayName }
        }
        if case .channel(let index) = destination {
            let channel = try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first
            if let channel { return channel.displayName }
        }
        return "New Message"
    }

    private var transcript: [MessageEntity] { messages.filter { !$0.isEmoji } }
    private var tapbacks: [Int64: [MessageEntity]] {
        Dictionary(grouping: messages.filter { $0.isEmoji && $0.replyId != 0 }, by: { $0.replyId })
    }

    // MARK: - Row snapshots (performance)
    //
    // Rendering straight from @Query cost 3 DB fetches + an NSDataDetector per
    // bubble per render. Rows are now precomputed once per change into value
    // snapshots; bubbles render dumb. Initial window is the newest 60 messages.

    struct RowModel: Identifiable {
        let message: MessageEntity
        let senderName: String?
        let senderMonogram: String?
        let senderIconData: Data?
        let replyPreview: String?
        let tapbacks: [MessageEntity]
        let linkified: AttributedString
        let coordinate: CLLocationCoordinate2D?
        let showsDaySeparator: Bool
        var id: Int64 { message.packetId }
    }

    @State private var rows: [RowModel] = []
    @State private var visibleCount = 60

    private var hiddenEarlierCount: Int { max(0, transcript.count - visibleCount) }

    private func rebuildRows() {
        let visible = Array(transcript.suffix(visibleCount))
        // One fetch for every sender in the window.
        let senderNums = Set(visible.map(\.fromNum))
        var senders: [Int64: NodeEntity] = [:]
        if !senderNums.isEmpty {
            let fetched = (try? modelContext.fetch(FetchDescriptor<NodeEntity>(
                predicate: #Predicate { senderNums.contains($0.num) }))) ?? []
            for node in fetched { senders[node.num] = node }
        }
        let tapbackMap = tapbacks
        let byId = Dictionary(uniqueKeysWithValues: transcript.map { ($0.packetId, $0.text) })
        let dm = isDM
        var built: [RowModel] = []
        built.reserveCapacity(visible.count)
        for (index, message) in visible.enumerated() {
            let sender = senders[message.fromNum]
            let showSender = !dm && !message.outgoing
            let separator = index == 0
                ? hiddenEarlierCount == 0
                : !Calendar.current.isDate(message.timestamp, inSameDayAs: visible[index - 1].timestamp)
            built.append(RowModel(
                message: message,
                senderName: showSender ? (sender.map { $0.customName.isEmpty ? $0.shortName : $0.customName } ?? String(format: "%04x", UInt32(truncatingIfNeeded: message.fromNum) & 0xFFFF)) : nil,
                senderMonogram: showSender ? sender?.monogram : nil,
                senderIconData: showSender ? sender?.iconData : nil,
                replyPreview: message.replyId != 0 ? byId[message.replyId] : nil,
                tapbacks: tapbackMap[message.packetId] ?? [],
                linkified: Self.linkify(message.text),
                coordinate: message.sharedCoordinate,
                showsDaySeparator: separator))
        }
        rows = built
    }

    /// Shared detector — building one per bubble was a hidden hot spot.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkify(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard text.contains("."), let detector = linkDetector else { return attributed }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: fullRange) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptView
            inputBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    MonogramAvatar(text: peerMonogram, isChannel: !isDM, size: 28,
                                   assetImage: isDM ? nil : MetroPresetStore.shared.channelIconAsset(forChannelIndex: conversation?.channelIndex ?? -1),
                                   imageData: peerIconData)
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    // PKI state at a glance: locked = end-to-end encrypted DM.
                    if isDM, let security = peerSecurity {
                        if security.keyChanged {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if security.hasKey {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if isDM {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPeerCard = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showPeerCard) {
            if case .node(let num) = destination {
                NodeCardView(nodeNum: num)
                    .presentationDetents([.medium])
            }
        }
        .sheet(item: $reactionTarget) { target in
            EmojiReactionSheet { emoji in
                sendTapback(emoji, to: target)
                reactionTarget = nil
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $reactionDetails) { target in
            ReactionDetailsSheet(tapbacks: tapbacks[target.packetId] ?? [])
                .presentationDetents([.medium])
        }
        .sheet(item: $senderCard) { num in
            NodeCardView(nodeNum: num) {
                senderCard = nil
                appModel.openConversation(ConversationEntity.dmKey(num))
            }
            .presentationDetents([.medium])
        }
        .onAppear {
            radio.activeConversationKey = conversationKey
            markRead()
        }
        .onDisappear {
            if radio.activeConversationKey == conversationKey {
                radio.activeConversationKey = nil
            }
        }
        .onChange(of: transcript.count) {
            markRead()
        }
        .alert("Can't get your location", isPresented: $locationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow location access for Hops in Settings, then try again.")
        }
    }

    // MARK: - Transcript

    @GestureState private var timeReveal: CGFloat = 0

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if hiddenEarlierCount > 0 {
                        Button {
                            let anchor = rows.first?.id
                            visibleCount += 150
                            rebuildRows()
                            if let anchor {
                                proxy.scrollTo(anchor, anchor: .top)
                            }
                        } label: {
                            Text("Load Earlier Messages (\(hiddenEarlierCount))")
                                .font(.footnote)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                    ForEach(rows) { row in
                        if row.showsDaySeparator {
                            Text(row.message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        timeRevealRow(for: row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // iMessage's timestamp reveal: drag left anywhere on the transcript.
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .updating($timeReveal) { value, state, _ in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        state = max(-72, min(0, value.translation.width))
                    }
            )
            // Explicit bottom management. defaultScrollAnchor(.bottom) mis-lands
            // when content grows after layout (map cards, status lines) and can
            // blank the pane entirely when the keyboard moves the safe area.
            .onAppear {
                rebuildRows()
                scrollToBottom(proxy, animated: false)
                // Second pass catches late layout (async map tiles, images).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: messages.count) {
                rebuildRows()
                scrollToBottom(proxy, animated: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = transcript.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.packetId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.packetId, anchor: .bottom)
        }
    }

    private func timeRevealRow(for row: RowModel) -> some View {
        ZStack(alignment: .trailing) {
            bubbleRow(for: row)
                .offset(x: timeReveal)
            Text(row.message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: 80 + timeReveal)
                .opacity(timeReveal < -10 ? 1 : 0)
        }
        .animation(.spring(duration: 0.3), value: timeReveal)
        .id(row.id)
    }

    private func bubbleRow(for row: RowModel) -> some View {
        let message = row.message
        return MessageBubble(
            message: message,
            isDM: isDM,
            senderName: row.senderName,
            senderMonogram: row.senderMonogram,
            senderIconData: row.senderIconData,
            replyPreview: row.replyPreview,
            linkified: row.linkified,
            coordinate: row.coordinate,
            tapbacks: row.tapbacks,
            onReply: { replyTarget = message },
            onTapback: { emoji in sendTapback(emoji, to: message) },
            onReactOther: { reactionTarget = message },
            onShowReactions: { reactionDetails = message },
            onShowSender: { senderCard = message.fromNum },
            onSendNow: { radio.forceSendNow(packetId: message.packetId) },
            onRetry: { radio.retry(packetId: message.packetId) }
        )
    }

    // MARK: - Input

    private var draftBytes: Int { draft.utf8.count }
    private var nearLimit: Bool { draftBytes > Self.byteLimit - 40 }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let target = replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption)
                    Text(target.text)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.thinMaterial)
            }
            HStack(alignment: .bottom, spacing: 8) {
                plusMenu
                HStack(alignment: .bottom) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .onChange(of: draft) { _, newValue in
                            // Hard stop at the LoRa payload limit — no surprise truncation.
                            while newValue.utf8.count > Self.byteLimit {
                                draft.removeLast()
                                return
                            }
                        }
                    if nearLimit {
                        Text("\(Self.byteLimit - draftBytes)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(draftBytes >= Self.byteLimit ? .red : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Special sends live behind a deliberate "+" so location can't be fat-fingered.
    private var plusMenu: some View {
        Menu {
            Button {
                shareLocation()
            } label: {
                Label("Send My Location", systemImage: "location.fill")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Send something special")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let destination else { return }
        radio.sendText(text, to: destination, replyId: replyTarget?.packetId ?? 0)
        draft = ""
        replyTarget = nil
    }

    private func sendTapback(_ emoji: String, to message: MessageEntity) {
        guard let destination else { return }
        radio.sendText(emoji, to: destination, isEmoji: true, replyId: message.packetId)
    }

    @State private var locationFailed = false

    private func shareLocation() {
        guard let destination else { return }
        Task {
            guard let location = await LocationProvider.shared.current() else {
                locationFailed = true
                return
            }
            let lat = location.coordinate.latitude
            let lon = location.coordinate.longitude
            // Text so it's visible in any client's transcript (with delivery
            // state), plus the standard waypoint so maps get a pin.
            radio.sendText(String(format: "📍 %.5f, %.5f", lat, lon), to: destination)
            radio.sendCurrentPosition(latitude: lat, longitude: lon, to: destination)
        }
    }

    private func markRead() {
        conversation?.unreadCount = 0   // instant UI; the actor does the rows
        NotificationManager.shared.clearNotifications(for: conversationKey)
        let key = conversationKey
        Task {
            let store = MessageStore(modelContainer: modelContext.container)
            await store.markConversationRead(key: key)
            let unread = await store.totalUnreadConversations()
            await NotificationManager.shared.setBadge(unread)
        }
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: MessageEntity
    let isDM: Bool
    let senderName: String?
    var senderMonogram: String? = nil
    var senderIconData: Data? = nil
    let replyPreview: String?
    var linkified: AttributedString = AttributedString()
    var coordinate: CLLocationCoordinate2D? = nil
    let tapbacks: [MessageEntity]
    var onReply: () -> Void
    var onTapback: (String) -> Void
    var onReactOther: () -> Void
    var onShowReactions: () -> Void
    var onShowSender: () -> Void
    var onSendNow: () -> Void = {}
    var onRetry: () -> Void

    private static let tapbackChoices = ["❤️", "👍", "👎", "🤣", "‼️", "❓"]

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
            if let senderName {
                Button(action: onShowSender) {
                    Text(senderName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)   // clears the avatar under it
            }
            HStack(alignment: .bottom, spacing: 6) {
                if message.outgoing { Spacer(minLength: 48) }
                if let senderName, !message.outgoing {
                    Button(action: onShowSender) {
                        MonogramAvatar(text: senderMonogram ?? senderName, isChannel: false, size: 26,
                                       imageData: senderIconData)
                    }
                    .buttonStyle(.plain)
                }
                bubbleContent
                    // Reaction pill rides the bubble's top corner, iMessage-style.
                    .overlay(alignment: message.outgoing ? .topLeading : .topTrailing) {
                        if !tapbacks.isEmpty {
                            Button(action: onShowReactions) {
                                Text(tapbacks.map { $0.text }.joined())
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .offset(x: message.outgoing ? -14 : 14, y: -14)
                        }
                    }
                if !message.outgoing { Spacer(minLength: 48) }
            }
            .padding(.top, tapbacks.isEmpty ? 0 : 10)   // room for the pill
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let replyPreview {
                Text(replyPreview)
                    .font(.caption)
                    .lineLimit(1)
                    .opacity(0.7)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(linkified)
                .tint(message.outgoing ? .white : .accentColor)
            if let coordinate {
                LocationCard(coordinate: coordinate, title: senderName ?? (message.outgoing ? "My location" : "Shared location"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            message.outgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.systemGray5)),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .foregroundStyle(message.outgoing ? .white : .primary)
        .contextMenu {
            // Horizontal tapback row, like iMessage's bar.
            ControlGroup {
                ForEach(Self.tapbackChoices, id: \.self) { emoji in
                    Button(emoji) { onTapback(emoji) }
                }
            }
            .controlGroupStyle(.palette)
            Button {
                onReactOther()
            } label: {
                Label("More Reactions…", systemImage: "face.smiling")
            }
            Divider()
            Button {
                onReply()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if message.status == .failed {
                Button {
                    onRetry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            if message.status == .waitingForPeer {
                Button {
                    onSendNow()
                } label: {
                    Label("Send Now", systemImage: "paperplane")
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if message.outgoing {
            switch message.status {
            case .waitingForRadio:
                statusText("Waiting for radio…", color: .secondary)
            case .waitingForPeer:
                statusText("Waiting for their radio — sends when it's heard", color: .secondary)
            case .sending:
                statusText(stale ? "Still sending — mesh delivery can take a few minutes" : "Sending…",
                           color: .secondary)
            case .relayed:
                statusText("Relayed", color: .secondary)
            case .deliveredToRadio:
                statusText("Delivered to their radio", color: .secondary)
            case .sentToMesh:
                statusText("Sent to mesh", color: .secondary)
            case .failed:
                Button(action: onRetry) {
                    statusText(failureText + " — Retry", color: .red)
                }
            case .received:
                EmptyView()
            }
        }
    }

    private var stale: Bool {
        Date().timeIntervalSince(message.timestamp) > 20
    }

    private var failureText: String {
        if message.ackErrorRaw == -1 { return "No response" }
        if isDM { return "No response from their radio" }
        return "Couldn't send"
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
    }
}

// The shared node card lives in Views/NodeCardView.swift.

// MARK: - Shared-location card

extension MessageEntity {
    /// A coordinate pair in the text (e.g. "📍 40.71280, -74.00600").
    /// Requires ≥3 decimals per component so prices/versions don't match.
    var sharedCoordinate: CLLocationCoordinate2D? {
        guard let regex = try? NSRegularExpression(pattern: #"(-?\d{1,2}\.\d{3,8})\s*,\s*(-?\d{1,3}\.\d{3,8})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(match.range(at: 1), in: text),
              let lonRange = Range(match.range(at: 2), in: text),
              let lat = Double(text[latRange]), let lon = Double(text[lonRange]),
              abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Mini map rendered under a coordinate message; tapping opens Apple Maps.
struct LocationCard: View {
    let coordinate: CLLocationCoordinate2D
    let title: String

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))) {
            Marker(title, coordinate: coordinate)
        }
        .allowsHitTesting(false)   // static preview; the tap belongs to the card
        .frame(width: 220, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            item.name = title
            item.openInMaps()
        }
        .padding(.top, 2)
    }
}
