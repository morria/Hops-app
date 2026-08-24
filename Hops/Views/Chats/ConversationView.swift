import SwiftUI
import SwiftData
import CoreLocation

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

    private func senderIconData(_ message: MessageEntity) -> Data? {
        let num = message.fromNum
        return (try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
        ).first)?.iconData
    }

    private var title: String {
        if let convo = conversation { return convo.title }
        if case .node(let num) = destination {
            let node = try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first
            if let node { return node.longName }
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
    }

    // MARK: - Transcript

    @GestureState private var timeReveal: CGFloat = 0

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(transcript.enumerated()), id: \.element.packetId) { index, message in
                        if showsDaySeparator(at: index) {
                            Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        timeRevealRow(for: message)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            // iMessage's timestamp reveal: drag left anywhere on the transcript.
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .updating($timeReveal) { value, state, _ in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        state = max(-72, min(0, value.translation.width))
                    }
            )
            .onChange(of: transcript.count) {
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.packetId, anchor: .bottom) }
                }
            }
        }
    }

    private func timeRevealRow(for message: MessageEntity) -> some View {
        ZStack(alignment: .trailing) {
            bubbleRow(for: message)
                .offset(x: timeReveal)
            Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(x: 80 + timeReveal)
                .opacity(timeReveal < -10 ? 1 : 0)
        }
        .animation(.spring(duration: 0.3), value: timeReveal)
        .id(message.packetId)
    }

    private func bubbleRow(for message: MessageEntity) -> some View {
        MessageBubble(
            message: message,
            isDM: isDM,
            senderName: senderShortName(message),
            senderIconData: senderIconData(message),
            replyPreview: replyPreview(message),
            tapbacks: tapbacks[message.packetId] ?? [],
            onReply: { replyTarget = message },
            onTapback: { emoji in sendTapback(emoji, to: message) },
            onReactOther: { reactionTarget = message },
            onShowReactions: { reactionDetails = message },
            onShowSender: { senderCard = message.fromNum },
            onRetry: { radio.retry(packetId: message.packetId) }
        )
    }

    private func showsDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(transcript[index].timestamp,
                                        inSameDayAs: transcript[index - 1].timestamp)
    }

    private func senderShortName(_ message: MessageEntity) -> String? {
        guard !isDM, !message.outgoing else { return nil }
        let num = message.fromNum
        let node = try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
        ).first
        return node?.shortName ?? String(format: "%04x", UInt32(truncatingIfNeeded: num) & 0xFFFF)
    }

    private func replyPreview(_ message: MessageEntity) -> String? {
        guard message.replyId != 0 else { return nil }
        return transcript.first(where: { $0.packetId == message.replyId })?.text
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
                shareLocationButton
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

    private var shareLocationButton: some View {
        Button {
            shareLocation()
        } label: {
            Image(systemName: "location.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Share my location")
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

    private func shareLocation() {
        guard let destination else { return }
        let manager = CLLocationManager()
        manager.requestWhenInUseAuthorization()
        if let location = manager.location {
            radio.sendCurrentPosition(latitude: location.coordinate.latitude,
                                      longitude: location.coordinate.longitude,
                                      to: destination)
        }
    }

    private func markRead() {
        conversation?.unreadCount = 0
        for message in messages where !message.read {
            message.read = true
        }
        NotificationManager.shared.clearNotifications(for: conversationKey)
        Task {
            let container = modelContext.container
            let store = MessageStore(modelContainer: container)
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
    var senderIconData: Data? = nil
    let replyPreview: String?
    let tapbacks: [MessageEntity]
    var onReply: () -> Void
    var onTapback: (String) -> Void
    var onReactOther: () -> Void
    var onShowReactions: () -> Void
    var onShowSender: () -> Void
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
                        MonogramAvatar(text: senderName, isChannel: false, size: 26,
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
            Text(message.text)
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
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if message.outgoing {
            switch message.status {
            case .waitingForRadio:
                statusText("Waiting for radio…", color: .secondary)
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
