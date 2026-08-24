import SwiftUI
import SwiftData
import PhotosUI

struct ChatsListView: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var presetStore = MetroPresetStore.shared
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ConversationEntity.lastMessageAt, order: .reverse)
    private var conversations: [ConversationEntity]

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showCompose = false
    @State private var path = NavigationPath()
    @State private var deleteTarget: ConversationEntity?
    @State private var renameTarget: ConversationEntity?
    @State private var renameText = ""
    @State private var photoTarget: ConversationEntity?
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropBox: CropBox?

    struct CropBox: Identifiable {
        let id = UUID()
        let image: UIImage
        let target: ConversationEntity
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                // Outside the List so each pin long-presses independently — as a
                // List row, the context-menu preview lifted the whole grid at once.
                if searchText.isEmpty && !pinned.isEmpty {
                    pinnedGrid
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
                Group {
                    if conversations.isEmpty && searchText.isEmpty {
                        emptyState
                    } else {
                        conversationList
                    }
                }
                // Tapping or scrolling anywhere below the field releases focus
                // (simultaneous, so row taps still land).
                .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                ConversationView(conversationKey: key)
            }
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
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { _, item in
                // photoTarget survives the picker's dismissal (a separate flag
                // drives presentation) — clearing it via the presentation binding
                // was the old race that silently dropped the photo.
                guard let item, let target = photoTarget else { return }
                pickedPhoto = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        cropBox = CropBox(image: image, target: target)
                    }
                    photoTarget = nil
                }
            }
            .sheet(item: $cropBox) { box in
                AvatarCropView(image: box.image) { cropped in
                    setIconData(cropped.jpegData(compressionQuality: 0.85), for: box.target)
                }
            }
            .alert("Rename", isPresented: Binding(get: { renameTarget != nil },
                                                  set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget { applyRename(target) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Shown only on your devices. Leave blank to use the name from the mesh.")
            }
            .confirmationDialog("Delete this conversation?",
                                isPresented: Binding(get: { deleteTarget != nil },
                                                     set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Conversation", role: .destructive) {
                    if let target = deleteTarget {
                        deleteConversation(target)
                    }
                    deleteTarget = nil
                }
            } message: {
                Text("Removes the conversation and its messages from this phone. A channel that still exists on your radio will reappear empty; mesh messages can't be deleted remotely.")
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

    // MARK: - Header (top-aligned title; search and compose share a line)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Messages")
                    .font(.title2.bold())
                Spacer()
                StatusCapsule()
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: Capsule())
                Button {
                    showCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .medium))
                        .padding(9)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("New Message")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
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
        // Leading-aligned cells so the first pinned avatar lines up with the
        // conversation rows' avatars below; each name centers under its avatar.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16, alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            ForEach(pinned) { convo in
                Button {
                    path.append(convo.key)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MonogramAvatar(text: monogram(for: convo), isChannel: convo.kind == .channel, size: 64,
                                       assetImage: iconAsset(for: convo), imageData: iconData(for: convo))
                            .overlay(alignment: .topTrailing) {
                                if convo.unreadCount > 0 {
                                    unreadBadge(convo.unreadCount)
                                }
                            }
                        Text(convo.title)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 64)
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
                               assetImage: iconAsset(for: convo), imageData: iconData(for: convo))
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
            Button(role: .destructive) {
                deleteTarget = convo
            } label: {
                Label("Delete", systemImage: "trash")
            }
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

    private func currentOverride(for convo: ConversationEntity) -> String {
        switch convo.kind {
        case .channel:
            let index = convo.channelIndex
            return (try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first)?.customName ?? ""
        case .directMessage:
            let num = convo.peerNum
            return (try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first)?.customName ?? ""
        }
    }

    /// Local-only override; blank restores the mesh-reported name. The
    /// denormalized conversation title updates immediately.
    private func applyRename(_ convo: ConversationEntity) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        switch convo.kind {
        case .channel:
            let index = convo.channelIndex
            if let channel = try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first {
                channel.customName = trimmed
                convo.title = channel.displayName
            }
        case .directMessage:
            let num = convo.peerNum
            if let node = try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first {
                node.customName = trimmed
                convo.title = node.displayName
            }
        }
        try? modelContext.save()
    }

    private func deleteConversation(_ convo: ConversationEntity) {
        let key = convo.key
        NotificationManager.shared.clearNotifications(for: key)
        let messages = (try? modelContext.fetch(
            FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.conversationKey == key })
        )) ?? []
        for message in messages {
            modelContext.delete(message)
        }
        modelContext.delete(convo)
        try? modelContext.save()
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
        if convo.kind == .channel {
            Button {
                radio.announceNodeInfo(onChannel: convo.channelIndex)
            } label: {
                Label("Announce My Node Info", systemImage: "person.wave.2")
            }
        }
        Button {
            renameText = currentOverride(for: convo)
            renameTarget = convo
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button {
            photoTarget = convo
            showPhotoPicker = true
        } label: {
            Label("Set Photo…", systemImage: "photo")
        }
        if iconData(for: convo) != nil {
            Button(role: .destructive) {
                setIconData(nil, for: convo)
            } label: {
                Label("Remove Photo", systemImage: "photo.badge.exclamationmark")
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = convo
        } label: {
            Label("Delete Conversation", systemImage: "trash")
        }
    }

    private func iconData(for convo: ConversationEntity) -> Data? {
        switch convo.kind {
        case .channel:
            let index = convo.channelIndex
            return (try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first)?.iconData
        case .directMessage:
            let num = convo.peerNum
            return (try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first)?.iconData
        }
    }

    private func setIconData(_ data: Data?, for convo: ConversationEntity) {
        switch convo.kind {
        case .channel:
            let index = convo.channelIndex
            (try? modelContext.fetch(
                FetchDescriptor<ChannelEntity>(predicate: #Predicate { $0.index == index })
            ).first)?.iconData = data
        case .directMessage:
            let num = convo.peerNum
            (try? modelContext.fetch(
                FetchDescriptor<NodeEntity>(predicate: #Predicate { $0.num == num })
            ).first)?.iconData = data
        }
        try? modelContext.save()
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

    /// Search fetches on demand with limits pushed to the database — standing
    /// whole-table queries re-rendered this view on every packet heard.
    private func searchNodes(_ query: String) -> [NodeEntity] {
        var descriptor = FetchDescriptor<NodeEntity>(predicate: #Predicate {
            $0.longName.localizedStandardContains(query)
                || $0.shortName.localizedStandardContains(query)
                || $0.customName.localizedStandardContains(query)
        })
        descriptor.fetchLimit = 50
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func searchMessages(_ query: String) -> [MessageEntity] {
        var descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate {
            $0.isEmoji == false && $0.text.localizedStandardContains(query)
        })
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        descriptor.fetchLimit = 50
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Priority order: existing conversations first, then every known node (a result
    /// here starts a new DM even with no history), then message-text matches.
    private var searchResults: some View {
        let query = searchText
        let lowered = query.lowercased()
        let matchingConvos = conversations.filter { $0.title.lowercased().contains(lowered) }
        let existingDMKeys = Set(matchingConvos.map { $0.key })
        let matchingNodes = searchNodes(query).filter { node in
            node.num != radio.myNodeNum
                && node.isMessageable
                && !existingDMKeys.contains(ConversationEntity.dmKey(node.num))
        }
        let matchingMessages = searchMessages(query)
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
                                MonogramAvatar(text: node.monogram, isChannel: false, size: 36,
                                               dimmed: !node.isOnline, imageData: node.iconData)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.displayName)
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
        Self.formatRelativeDate(date)
    }

    static func formatRelativeDate(_ date: Date) -> String {
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
                                               assetImage: MetroPresetStore.shared.channelIconAsset(forChannelIndex: channel.index),
                                               imageData: channel.iconData)
                                Text(channel.displayName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("People") {
                    ForEach(messageableNodes.filter { query.isEmpty || $0.displayName.lowercased().contains(query) || $0.longName.lowercased().contains(query) || $0.shortName.lowercased().contains(query) }) { node in
                        Button {
                            onPick(ConversationEntity.dmKey(node.num))
                        } label: {
                            HStack {
                                MonogramAvatar(text: node.monogram, isChannel: false, size: 36,
                                               dimmed: !node.isOnline, imageData: node.iconData)
                                VStack(alignment: .leading) {
                                    Text(node.displayName)
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
