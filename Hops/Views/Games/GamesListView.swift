import SwiftUI
import SwiftData

/// The Games tab: what needs you, what's in progress, then every game you
/// can start (docs/GAMES.md §4).
struct GamesListView: View {
    @Query(sort: \GameSessionEntity.updatedAt, order: .reverse) private var sessions: [GameSessionEntity]
    @Query private var nodes: [NodeEntity]
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var radio: RadioManager
    @State private var newGameKind: GameKind?
    @State private var path: [PersistentIdentifier] = []

    private var names: [Int64: NodeEntity] {
        Dictionary(nodes.map { ($0.num, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var invitations: [GameSessionEntity] { sessions.filter { $0.phase == .invited } }
    private var active: [GameSessionEntity] {
        sessions.filter { [.myTurn, .waiting, .theirTurn, .inviting].contains($0.phase) }
    }
    private var finished: [GameSessionEntity] {
        sessions.filter { [.finished, .declined].contains($0.phase) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
        }
    }

    private var list: some View {
        List {
            if !invitations.isEmpty {
                Section("Invitations") {
                    ForEach(invitations) { session in sessionRow(session) }
                }
            }
            if !active.isEmpty {
                Section("In progress") {
                    ForEach(active) { session in sessionRow(session) }
                        .onDelete { offsets in
                            for i in offsets { GameCoordinator.shared.delete(active[i]) }
                        }
                }
            }
            Section {
                ForEach(GameKind.allCases, id: \.rawValue) { kind in
                    Button {
                        newGameKind = kind
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.icon)
                                .font(.title3)
                                .frame(width: 32)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).foregroundStyle(.primary)
                                Text(kind.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let open = active.filter { $0.kind == kind }.count
                            if open > 0 {
                                Text("\(open)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("New game")
            } footer: {
                Text("Invite another Hops user. Moves travel over the mesh and count only once both phones agree.")
            }
            if !finished.isEmpty {
                Section("Finished") {
                    ForEach(finished.prefix(20)) { session in sessionRow(session) }
                        .onDelete { offsets in
                            let shown = Array(finished.prefix(20))
                            for i in offsets { GameCoordinator.shared.delete(shown[i]) }
                        }
                }
            }
        }
        .navigationTitle("Games")
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let session = sessions.first(where: { $0.persistentModelID == id }) {
                GameSessionView(session: session, peer: names[session.peerNum])
            }
        }
        .sheet(item: $newGameKind) { kind in
            NewGameSheet(kind: kind) { session in
                path = [session.persistentModelID]
            }
        }
        .onChange(of: appModel.pendingGameSessionId) { _, sid in
            guard let sid, let session = sessions.first(where: { $0.sessionId == sid }) else { return }
            appModel.pendingGameSessionId = nil
            path = [session.persistentModelID]
        }
        .onAppear {
            if let sid = appModel.pendingGameSessionId, let session = sessions.first(where: { $0.sessionId == sid }) {
                appModel.pendingGameSessionId = nil
                path = [session.persistentModelID]
            }
        }
    }

    private func sessionRow(_ session: GameSessionEntity) -> some View {
        NavigationLink(value: session.persistentModelID) {
            HStack(spacing: 12) {
                let node = names[session.peerNum]
                MonogramAvatar(text: node?.monogram ?? "?", isChannel: false, size: 40,
                               dimmed: !(node?.isOnline ?? false), imageData: node?.iconData)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.kind.title)
                        Text("with \(node?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: session.peerNum)))")
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Text(statusText(session))
                        .font(.caption)
                        .foregroundStyle(session.needsAttention ? Color.accentColor : .secondary)
                }
                Spacer()
                if session.needsAttention {
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                }
            }
        }
    }

    private func statusText(_ session: GameSessionEntity) -> String {
        switch session.phase {
        case .inviting: return "Invitation sent · \(session.updatedAt.formatted(.relative(presentation: .named)))"
        case .invited: return "Invites you to play"
        case .myTurn: return session.drawOffered ? "Draw offered - your turn" : "Your turn"
        case .waiting: return "Move sent - waiting for agreement"
        case .theirTurn: return "Their turn · \(session.updatedAt.formatted(.relative(presentation: .named)))"
        case .finished: return session.resultText ?? "Finished"
        case .declined: return "Declined"
        }
    }
}

extension GameKind: Identifiable {
    var id: UInt8 { rawValue }
}

// MARK: - New game: pick an opponent

struct NewGameSheet: View {
    let kind: GameKind
    var onCreated: (GameSessionEntity) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var radio: RadioManager
    @Query(sort: \NodeEntity.longName) private var nodes: [NodeEntity]
    @Query private var conversations: [ConversationEntity]
    @State private var searchText = ""
    @State private var iMoveFirst = true
    @State private var peer: NodeEntity?

    private var candidates: [NodeEntity] {
        let query = searchText.lowercased()
        return nodes.filter { !radio.isMine($0.num) && $0.isMessageable }
            .filter { query.isEmpty || $0.displayName.lowercased().contains(query) || $0.shortName.lowercased().contains(query) }
    }

    /// Pinned DM threads and renamed nodes: the people you actually play
    /// with, ahead of the whole node list (TODO 203).
    private var pinnedNums: Set<Int64> {
        Set(conversations.filter { $0.kind == .directMessage && $0.pinned }.map(\.peerNum))
    }
    private var favorites: [NodeEntity] {
        candidates.filter { pinnedNums.contains($0.num) || !$0.customName.isEmpty }
            .sorted { a, b in
                let pa = pinnedNums.contains(a.num), pb = pinnedNums.contains(b.num)
                if pa != pb { return pa }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }
    private var others: [NodeEntity] {
        let favored = Set(favorites.map(\.num))
        return candidates.filter { !favored.contains($0.num) }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("First move", selection: $iMoveFirst) {
                        Text("Me").tag(true)
                        Text("Them").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(firstMoveFooter)
                }
                if !favorites.isEmpty {
                    Section("Favorites & named") {
                        ForEach(favorites) { node in inviteRow(node) }
                    }
                }
                Section(favorites.isEmpty ? "Invite" : "Everyone else") {
                    ForEach(others) { node in inviteRow(node) }
                }
            }
            .navigationTitle("New Game")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func inviteRow(_ node: NodeEntity) -> some View {
        Button {
            guard let session = GameCoordinator.shared.invite(kind: kind, peer: node.num,
                                                              iMoveFirst: iMoveFirst) else { return }
            dismiss()
            onCreated(session)
        } label: {
            HStack(spacing: 12) {
                MonogramAvatar(text: node.monogram, isChannel: false, size: 36,
                               dimmed: !node.isOnline, imageData: node.iconData)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(node.displayName)
                        if pinnedNums.contains(node.num) {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let heard = node.lastHeard {
                        Text("Heard \(heard.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var firstMoveFooter: String {
        switch kind {
        case .chess: return "Whoever moves first plays White."
        case .checkers: return "Whoever moves first plays the dark pieces."
        case .battleship: return "Whoever moves first fires the first shot. Both of you place ships privately first."
        default: return "The other player needs Games turned on in Hops to answer."
        }
    }
}
