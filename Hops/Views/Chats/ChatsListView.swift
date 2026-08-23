import SwiftUI
import SwiftData

struct ChatsListView: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var presetStore = MetroPresetStore.shared
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ConversationEntity.lastMessageAt, order: .reverse)
    private var conversations: [ConversationEntity]

    @State private var searchText = ""
    @State private var showCompose = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { key in
                ConversationView(conversationKey: key)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Message")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                StatusCapsule()
                    .padding(.top, 2)
            }
            .searchable(text: $searchText, prompt: "Search")
            .sheet(isPresented: $showCompose) {
                ComposePickerView { key in
                    showCompose = false
                    path.append(key)
                }
            }
            .onChange(of: appModel.pendingConversationKey) { _, key in
                guard let key else { return }
                appModel.pendingConversationKey = nil
                path.append(key)
            }
            .onAppear {
                // Consume a deep link that arrived while this tab wasn't built yet
                // (e.g. the map's Message button on first use).
                if let key = appModel.pendingConversationKey {
                    appModel.pendingConversationKey = nil
                    path.append(key)
                }
                #if DEBUG
                if let key = ScreenshotMode.initialConversation, path.isEmpty {
                    path.append(key)
                }
                #endif
            }
        }
    }

    // MARK: - List

    private var pinned: [ConversationEntity] {
        conversations.filter { $0.pinned }
    }

    private var unpinned: [ConversationEntity] {
        conversations.filter { !$0.pinned && ($0.lastMessageAt != nil || $0.kind == .channel) }
    }

    private var conversationList: some View {
        List {
            if searchText.isEmpty {
                if !pinned.isEmpty {
                    Section {
                        pinnedGrid
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(unpinned) { convo in
                        row(for: convo)
                    }
                }
            } else {
                searchResults
            }
        }
        .listStyle(.plain)
    }

    private var pinnedGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 12) {
            ForEach(pinned) { convo in
                Button {
                    path.append(convo.key)
                } label: {
                    VStack(spacing: 6) {
                        MonogramAvatar(text: monogram(for: convo), isChannel: convo.kind == .channel, size: 64,
                                       assetImage: iconAsset(for: convo))
                            .overlay(alignment: .topTrailing) {
                                if convo.unreadCount > 0 {
                                    unreadBadge(convo.unreadCount)
                                }
                            }
                        Text(convo.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { swipeMenuItems(for: convo) }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(for convo: ConversationEntity) -> some View {
        Button {
            path.append(convo.key)
        } label: {
            HStack(spacing: 12) {
                MonogramAvatar(text: monogram(for: convo), isChannel: convo.kind == .channel,
                               assetImage: iconAsset(for: convo))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(convo.title)
                            .font(.body.weight(convo.unreadCount > 0 ? .semibold : .regular))
                            .lineLimit(1)
                        switch convo.notifyLevel {
                        case .muted:
                            Image(systemName: "bell.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        case .mentionsOnly:
                            Image(systemName: "at.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        case .all:
                            EmptyView()
                        }
                        Spacer()
                        if let date = convo.lastMessageAt {
                            Text(relativeDate(date))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top) {
                        Text(convo.lastPreview.isEmpty ? "No messages yet" : convo.lastPreview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        if convo.unreadCount > 0 {
                            unreadBadge(convo.unreadCount)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                togglePin(convo)
            } label: {
                Label(convo.pinned ? "Unpin" : "Pin", systemImage: convo.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
            Button {
                toggleRead(convo)
            } label: {
                Label(convo.unreadCount > 0 ? "Read" : "Unread",
                      systemImage: convo.unreadCount > 0 ? "message.badge.filled.fill" : "message.badge")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button {
                convo.notifyLevel = convo.notifyLevel == .muted ? .all : .muted
            } label: {
                Label(convo.notifyLevel == .muted ? "Unmute" : "Mute",
                      systemImage: convo.notifyLevel == .muted ? "bell" : "bell.slash")
            }
            .tint(.indigo)
        }
        .contextMenu { swipeMenuItems(for: convo) }
    }

    @ViewBuilder
    private func swipeMenuItems(for convo: ConversationEntity) -> some View {
        Button {
            togglePin(convo)
        } label: {
            Label(convo.pinned ? "Unpin" : "Pin", systemImage: convo.pinned ? "pin.slash" : "pin")
        }
        Picker("Notifications", selection: Binding(
            get: { convo.notifyLevel.rawValue },
            set: { convo.notifyLevel = NotifyLevel(rawValue: $0) ?? .all }
        )) {
            Label("All Messages", systemImage: "bell").tag(NotifyLevel.all.rawValue)
            Label("Mentions Only", systemImage: "at").tag(NotifyLevel.mentionsOnly.rawValue)
            Label("Muted", systemImage: "bell.slash").tag(NotifyLevel.muted.rawValue)
        }
        .pickerStyle(.menu)
    }

    private func unreadBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
    }

    // MARK: - Search

    @Query private var allMessages: [MessageEntity]
    @Query private var allNodes: [NodeEntity]

    /// Priority order: existing conversations first, then every known node (a result
    /// here starts a new DM even with no history), then message-text matches.
    private var searchResults: some View {
        let query = searchText.lowercased()
        let matchingConvos = conversations.filter { $0.title.lowercased().contains(query) }
        let existingDMKeys = Set(matchingConvos.map { $0.key })
        let matchingNodes = allNodes.filter { node in
            node.num != radio.myNodeNum
                && node.isMessageable
                && (node.longName.lowercased().contains(query) || node.shortName.lowercased().contains(query))
                && !existingDMKeys.contains(ConversationEntity.dmKey(node.num))
        }
        let matchingMessages = allMessages
            .filter { !$0.isEmoji && $0.text.lowercased().contains(query) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(50)
        return Group {
            if !matchingConvos.isEmpty {
                Section("Conversations") {
                    ForEach(matchingConvos) { convo in
                        row(for: convo)
                    }
                }
            }
            if !matchingNodes.isEmpty {
                Section("Nodes") {
                    ForEach(matchingNodes) { node in
                        Button {
                            path.append(ConversationEntity.dmKey(node.num))
                        } label: {
                            HStack(spacing: 12) {
                                MonogramAvatar(text: node.monogram, isChannel: false, size: 36, dimmed: !node.isOnline)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.longName)
                                    if let heard = node.lastHeard {
                                        Text("Heard \(heard.formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No messages yet")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !matchingMessages.isEmpty {
                Section("Messages") {
                    ForEach(Array(matchingMessages)) { message in
                        Button {
                            path.append(message.conversationKey)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversationTitle(for: message.conversationKey))
                                    .font(.subheadline.weight(.semibold))
                                Text(message.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func conversationTitle(for key: String) -> String {
        conversations.first(where: { $0.key == key })?.title ?? key
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Channels you join and people you message appear here.\nMesh messages are text only, up to ~200 characters — that's LoRa.")
        } actions: {
            Button("New Message") { showCompose = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func iconAsset(for convo: ConversationEntity) -> String? {
        guard convo.kind == .channel else { return nil }
        return presetStore.channelIconAsset(forChannelIndex: convo.channelIndex)
    }

    private func monogram(for convo: ConversationEntity) -> String {
        if convo.kind == .channel { return "#" }
        let peer = convo.peerNum
        if let node = try? modelContext.fetch(
            FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == peer })
        ).first {
            return node.monogram
        }
        return String(convo.title.prefix(2))
    }

    private func togglePin(_ convo: ConversationEntity) {
        withAnimation { convo.pinned.toggle() }
    }

    private func toggleRead(_ convo: ConversationEntity) {
        if convo.unreadCount > 0 {
            convo.unreadCount = 0
        } else {
            convo.unreadCount = 1
        }
    }

    private func relativeDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Compose picker

struct ComposePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChannelEntity.index) private var channels: [ChannelEntity]
    @Query(sort: \NodeEntity.longName) private var nodes: [NodeEntity]
    @EnvironmentObject private var radio: RadioManager
    @State private var searchText = ""

    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                let query = searchText.lowercased()
                Section("Channels") {
                    ForEach(channels.filter { $0.isActive && (query.isEmpty || $0.displayName.lowercased().contains(query)) }) { channel in
                        Button {
                            onPick(ConversationEntity.channelKey(channel.index))
                        } label: {
                            HStack {
                                MonogramAvatar(text: "#", isChannel: true, size: 36,
                                               assetImage: MetroPresetStore.shared.channelIconAsset(forChannelIndex: channel.index))
                                Text(channel.displayName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("People") {
                    ForEach(messageableNodes.filter { query.isEmpty || $0.longName.lowercased().contains(query) || $0.shortName.lowercased().contains(query) }) { node in
                        Button {
                            onPick(ConversationEntity.dmKey(node.num))
                        } label: {
                            HStack {
                                MonogramAvatar(text: node.monogram, isChannel: false, size: 36, dimmed: !node.isOnline)
                                VStack(alignment: .leading) {
                                    Text(node.longName)
                                    if let heard = node.lastHeard {
                                        Text("Heard \(heard.formatted(.relative(presentation: .named)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Channel or name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Nodes that can actually answer: not our own radio, not router/repeater/sensor roles.
    private var messageableNodes: [NodeEntity] {
        nodes.filter { $0.num != radio.myNodeNum && $0.isMessageable }
    }
}
