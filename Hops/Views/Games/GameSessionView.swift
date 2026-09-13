import SwiftUI
import SwiftData

/// One game: status, board, controls, move log. The board is locked while
/// a move is in flight — nothing counts until the other phone agrees.
struct GameSessionView: View {
    @Bindable var session: GameSessionEntity
    let peer: NodeEntity?
    @ObservedObject private var coordinator = GameCoordinator.shared
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss
    @State private var showResign = false
    @State private var showResync = false
    @State private var nudged = false
    @State private var now = Date()
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var record: GameSessionRecord { session.record }
    private var peerName: String {
        peer?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: session.peerNum))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                if session.phase == .invited {
                    inviteButtons
                } else if session.phase != .declined {
                    GameBoardView(context: boardContext)
                        .padding(.horizontal)
                }
                if session.drawOffered, record.isActive {
                    Button("Accept draw") { coordinator.acceptDraw(session) }
                        .buttonStyle(.borderedProminent)
                }
                moveLog
            }
            .padding(.vertical)
        }
        .navigationTitle("\(session.kind.title) with \(peerName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if [.waiting, .inviting, .theirTurn].contains(session.phase) {
                        Button {
                            nudged = coordinator.nudge(session)
                        } label: {
                            Label(session.phase == .waiting ? "Resend last move"
                                  : session.phase == .inviting ? "Resend invitation" : "Nudge",
                                  systemImage: "arrow.clockwise")
                        }
                    }
                    if record.isActive || record.outOfSync {
                        Button {
                            showResync = true
                        } label: { Label("Re-sync from their board", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    if record.isActive {
                        Button { coordinator.offerDraw(session) } label: { Label("Offer draw", systemImage: "equal") }
                        Button(role: .destructive) { showResign = true } label: { Label("Resign", systemImage: "flag") }
                    }
                    Button(role: .destructive) {
                        coordinator.delete(session); dismiss()
                    } label: { Label("Delete game", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Resign this game?", isPresented: $showResign, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { coordinator.resign(session) }
        }
        .confirmationDialog("Re-sync from their board?", isPresented: $showResync, titleVisibility: .visible) {
            Button("Adopt their moves", role: .destructive) { coordinator.resyncFromPeer(session) }
        } message: {
            Text("Your copy of this game will be replaced by the other phone's move list. Use this when the boards no longer match.")
        }
        .onAppear { coordinator.markSeen(session) }
        .onChange(of: session.needsAttention) { _, needs in if needs { coordinator.markSeen(session) } }
        .onReceive(ticker) { now = $0 }
    }

    private var boardContext: GameBoardContext {
        GameBoardContext(engine: record.engineWithPending(), myPlayer: session.myPlayer,
                         interactive: session.phase == .myTurn && record.result == nil,
                         privateData: session.privateData,
                         onMove: { coordinator.play($0, in: session) },
                         onPrivateSetup: { coordinator.setPrivateData($0, for: session) })
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(headline)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var headline: String {
        switch session.phase {
        case .inviting: return "Waiting for \(peerName) to accept"
        case .invited: return "\(peerName) invites you to play"
        case .myTurn: return "Your turn"
        case .waiting: return "Move sent - waiting for agreement"
        case .theirTurn: return "\(peerName)'s turn"
        case .finished: return session.resultText ?? "Game over"
        case .declined: return "Declined"
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if record.adoptingPeerLog { parts.append("Asked for their board - waiting for their moves.") }
        else if record.outOfSync { parts.append("Out of sync - the boards differ. Use Re-sync from their board in the menu.") }
        if let nak = record.lastNak, session.phase == .myTurn { parts.append(nak.text) }
        switch session.phase {
        case .waiting, .inviting:
            if radio.state != .connected {
                parts.append("Will send when your radio reconnects.")
            } else if let error = coordinator.routingErrors[session.persistentModelID], error != 0 {
                parts.append("Their radio didn't take it (error \(error)). Retrying with backoff.")
            } else if coordinator.deliveredToRadio.contains(session.persistentModelID) {
                parts.append("Reached their radio; waiting for their app to answer.")
            } else if let at = session.lastSentAt {
                parts.append("Sent \(at.formatted(.relative(presentation: .named))). Resends automatically.")
            }
            if session.phase == .inviting, now.timeIntervalSince(session.createdAt) > 24 * 60 * 60 {
                parts.append("No answer in a day - they may not have Games turned on.")
            }
            if nudged { parts.append("Resent.") }
        case .theirTurn:
            parts.append("You'll get a notification when they move.")
        case .myTurn where session.kind.needsPrivateSetup && session.privateData.isEmpty:
            parts.append("Place your ships first.")
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var inviteButtons: some View {
        HStack(spacing: 12) {
            Button("Decline", role: .destructive) { coordinator.decline(session) }
                .buttonStyle(.bordered)
            Button("Accept") { coordinator.accept(session) }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Move log

    private var moveLog: some View {
        let engine = session.kind.make(options: session.options)
        let size = session.kind.moveSize
        let moves = stride(from: 0, to: session.moves.count - size + 1, by: size).map { offset in
            session.moves.subdata(in: (session.moves.startIndex + offset)..<(session.moves.startIndex + offset + size))
        }
        return Group {
            if !moves.isEmpty || session.pendingMove != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moves").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(describeAll(moves).enumerated()), id: \.offset) { index, text in
                        HStack {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(text)
                        }
                        .font(.callout)
                    }
                    if let pending = session.pendingMove {
                        HStack {
                            Text("\(moves.count + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(engine.describe(pending)).italic()
                            Text("(unconfirmed)").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }
    }

    /// Describes each move in the position it was played from.
    private func describeAll(_ moves: [Data]) -> [String] {
        var engine = session.kind.make(options: session.options)
        var out: [String] = []
        for move in moves {
            let mover = engine.toMove == session.myPlayer ? "You" : peerName
            out.append("\(mover): \(engine.describe(move))")
            guard (try? engine.apply(move)) != nil else { break }
        }
        return out
    }
}

/// Dispatches to the engine's board.
struct GameBoardView: View {
    let context: GameBoardContext

    var body: some View {
        switch context.engine {
        case is TicTacToe: TicTacToeBoardView(context: context)
        case is ConnectFour: ConnectFourBoardView(context: context)
        case is DotsAndBoxes: DotsAndBoxesBoardView(context: context)
        case is Checkers: CheckersBoardView(context: context)
        case is Battleship: BattleshipBoardView(context: context)
        case is Chess: ChessBoardView(context: context)
        default: Text("Unsupported game")
        }
    }
}
