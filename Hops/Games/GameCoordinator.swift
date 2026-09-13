import Foundation
import SwiftData
import Combine
import OSLog

/// Owns game sessions: persists records, sends frames through the transmit
/// radio, resends what's in flight, and turns protocol events into
/// notifications (docs/GAMES.md §3). Pure rules live in `GameLogic`.
@MainActor
final class GameCoordinator: ObservableObject {
    static let shared = GameCoordinator()
    static let port: Int = 425

    private let log = Logger(subsystem: "com.w2asm.hops", category: "games")
    private var context: ModelContext?
    private var cancellables: Set<AnyCancellable> = []
    private var retryTimer: Timer?

    /// Packet ids of frames in flight → session, so routing acks can show
    /// "delivered to their radio" (distinct from the app-level agreement).
    private var inFlight: [UInt32: PersistentIdentifier] = [:]
    @Published private(set) var deliveredToRadio: Set<PersistentIdentifier> = []
    @Published private(set) var routingErrors: [PersistentIdentifier: Int32] = [:]

    private init() {}

    func configure(container: ModelContainer) {
        context = container.mainContext
        RadioManager.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .connected else { return }
                Task { @MainActor in self?.resendAll(reason: "reconnect") }
            }
            .store(in: &cancellables)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryDue() }
        }
    }

    // MARK: - Lookup

    func sessions() -> [GameSessionEntity] {
        guard let context else { return [] }
        let d = FetchDescriptor<GameSessionEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    private func session(id: UInt32, peer: Int64) -> GameSessionEntity? {
        guard let context else { return nil }
        let sid = Int64(id)
        var d = FetchDescriptor<GameSessionEntity>(predicate: #Predicate { $0.sessionId == sid && $0.peerNum == peer })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    // MARK: - User actions

    @discardableResult
    func invite(kind: GameKind, peer: Int64, iMoveFirst: Bool) -> GameSessionEntity? {
        guard let context else { return nil }
        let me: Player = iMoveFirst ? .one : .two
        let id = UInt32.random(in: 1...UInt32.max)
        let record = GameSessionRecord(id: id, kind: kind, peer: peer, me: me,
                                       options: Data([me.rawValue]), phase: .inviting)
        let entity = GameSessionEntity(record: record)
        context.insert(entity)
        save()
        send(GameLogic.inviteFrame(record), for: entity)
        return entity
    }

    func play(_ move: Data, in entity: GameSessionEntity) {
        var r = entity.record
        guard let frame = GameLogic.play(move, in: &r) else { return }
        entity.apply(r); entity.needsAttention = false
        entity.sendAttempts = 0
        save()
        send(frame, for: entity)
    }

    func accept(_ entity: GameSessionEntity) {
        var r = entity.record
        guard let frame = GameLogic.accept(&r) else { return }
        entity.apply(r); entity.needsAttention = r.phase == .myTurn
        save()
        send(frame, for: entity)
        autoMoveIfNeeded(entity)
    }

    func decline(_ entity: GameSessionEntity) {
        var r = entity.record
        guard let frame = GameLogic.decline(&r) else { return }
        entity.apply(r); entity.needsAttention = false
        save()
        send(frame, for: entity)
    }

    func resign(_ entity: GameSessionEntity) {
        var r = entity.record
        guard let frame = GameLogic.resign(&r) else { return }
        entity.apply(r); entity.needsAttention = false
        save()
        send(frame, for: entity)
    }

    func offerDraw(_ entity: GameSessionEntity) {
        guard let frame = GameLogic.offerDraw(entity.record) else { return }
        send(frame, for: entity)
    }

    func acceptDraw(_ entity: GameSessionEntity) {
        var r = entity.record
        guard let frame = GameLogic.acceptDraw(&r) else { return }
        entity.apply(r); entity.needsAttention = false
        save()
        send(frame, for: entity)
    }

    /// Hidden setup chosen (Battleship placement). May unblock an auto move.
    func setPrivateData(_ data: Data, for entity: GameSessionEntity) {
        entity.privateData = data
        entity.updatedAt = Date()
        save()
        autoMoveIfNeeded(entity)
    }

    /// "Nudge": resend whatever this game is waiting on, at most every 15 min.
    @discardableResult
    func nudge(_ entity: GameSessionEntity) -> Bool {
        if let last = entity.lastNudgeAt, Date().timeIntervalSince(last) < 15 * 60 { return false }
        let frames = GameLogic.resendFrames(entity.record)
        guard !frames.isEmpty else { return false }
        entity.lastNudgeAt = Date()
        for f in frames { send(f, for: entity) }
        return true
    }

    func markSeen(_ entity: GameSessionEntity) {
        guard entity.needsAttention else { return }
        entity.needsAttention = false
        save()
    }

    func delete(_ entity: GameSessionEntity) {
        guard let context else { return }
        if entity.record.isActive {
            send(.end(session: UInt32(truncatingIfNeeded: entity.sessionId), reason: .abandon), for: entity)
        }
        context.delete(entity)
        save()
    }

    // MARK: - Inbound

    func handle(from peer: Int64, payload: Data) {
        guard let context, let frame = GameFrame(payload) else {
            log.notice("games: undecodable frame from \(String(format: "!%08x", UInt32(truncatingIfNeeded: peer)))")
            return
        }
        let entity: GameSessionEntity
        if let existing = session(id: frame.session, peer: peer) {
            entity = existing
        } else if case .invite = frame, let record = GameLogic.newInvitedRecord(from: peer, frame: frame) {
            entity = GameSessionEntity(record: record)
            entity.needsAttention = true
            context.insert(entity)
            save()
            notify(.invited, entity)
            return
        } else {
            // Nothing we know about — tell them so their app stops waiting.
            let reply: GameFrame?
            switch frame {
            case .move(let s, let seq, _, _): reply = .nak(session: s, seq: seq, reason: .unknownSession)
            default: reply = nil
            }
            if let reply { RadioManager.shared.sendGames(to: peer, payload: reply.encoded()) }
            return
        }

        var record = entity.record
        let out = GameLogic.handle(frame, record: &record)
        if out.changed {
            entity.apply(record)
            if out.events.contains(where: { [.yourTurn, .finished, .drawOffered, .accepted].contains($0) }) {
                entity.needsAttention = true
            }
            if case .rejected? = out.events.first { entity.needsAttention = true }
            entity.sendAttempts = 0
            deliveredToRadio.remove(entity.persistentModelID)
            save()
        }
        for reply in out.replies { send(reply, for: entity) }
        for event in out.events { notify(event, entity) }
        if out.changed { autoMoveIfNeeded(entity) }
    }

    /// Routing result for one of our frames: delivered to their radio or not.
    func noteRouting(packetId: UInt32, ok: Bool, error: Int32) {
        guard let id = inFlight.removeValue(forKey: packetId) else { return }
        if ok { deliveredToRadio.insert(id); routingErrors[id] = nil }
        else { routingErrors[id] = error }
    }

    // MARK: - Sending & retries

    private func send(_ frame: GameFrame, for entity: GameSessionEntity) {
        let radio = RadioManager.shared
        guard radio.state == .connected else {
            entity.lastSentAt = nil   // retried on reconnect
            return
        }
        let packetId = radio.sendGames(to: entity.peerNum, payload: frame.encoded())
        inFlight[packetId] = entity.persistentModelID
        deliveredToRadio.remove(entity.persistentModelID)
        routingErrors[entity.persistentModelID] = nil
        entity.lastSentAt = Date()
        entity.viaNodeNum = radio.myNodeNum
        save()
    }

    private func resendAll(reason: String) {
        var count = 0
        for entity in sessions() {
            let frames = GameLogic.resendFrames(entity.record)
            guard !frames.isEmpty else { continue }
            entity.sendAttempts = 0
            for f in frames { send(f, for: entity) }
            count += frames.count
        }
        if count > 0 { log.notice("games: resent \(count) frame(s) on \(reason)") }
    }

    /// Exponential backoff for frames still unanswered: 1, 2, 4 … 30 minutes.
    private func retryDue() {
        guard RadioManager.shared.state == .connected else { return }
        for entity in sessions() where [.inviting, .waiting].contains(entity.phase) {
            let frames = GameLogic.resendFrames(entity.record)
            guard !frames.isEmpty else { continue }
            let wait = min(60.0 * pow(2.0, Double(entity.sendAttempts)), 30 * 60)
            guard let last = entity.lastSentAt else {
                for f in frames { send(f, for: entity) }
                continue
            }
            if Date().timeIntervalSince(last) >= wait {
                entity.sendAttempts += 1
                for f in frames { send(f, for: entity) }
            }
        }
    }

    /// Battleship's hit/miss report: the engine answers for the player.
    private func autoMoveIfNeeded(_ entity: GameSessionEntity) {
        let r = entity.record
        guard r.phase == .myTurn, let auto = r.engine().autoMove(privateData: r.privateData) else { return }
        play(auto, in: entity)
    }

    private func save() {
        do { try context?.save() } catch { log.error("games: save failed \(error.localizedDescription)") }
    }

    // MARK: - Notifications

    private func notify(_ event: GameEvent, _ entity: GameSessionEntity) {
        let body: String
        switch event {
        case .invited: body = "invites you to play \(entity.kind.title)"
        case .yourTurn: body = "made a move in \(entity.kind.title) — your turn"
        case .finished: body = "\(entity.kind.title): \(entity.resultText ?? "game over")"
        case .drawOffered: body = "offers a draw in \(entity.kind.title)"
        case .accepted: body = "accepted your \(entity.kind.title) invitation"
        case .declined: body = "declined your \(entity.kind.title) invitation"
        case .rejected(let reason): body = "\(entity.kind.title): \(reason.text)"
        case .moveAgreed: return
        }
        guard !UIStateObserver.shared.isActive else { return }
        NotificationManager.shared.postGame(peer: entity.peerNum, sessionId: entity.sessionId, body: body)
    }
}
