#if MESHSITES
import Foundation
import Compression

/// Wire helpers for the serving side (client-side inflate lives in
/// MeshsitesManager).
enum MeshsitesWire {
    static func fnv1a(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    /// Raw DEFLATE (RFC 1951) via COMPRESSION_ZLIB — headerless, per spec.
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + 512
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(dst.prefix(written)) : Data()
    }
}

/// Serves the user's Meshsite over the radio: beacons while enabled and
/// connected, answers GET with cached-or-chunked pages, records every POST
/// to the replies file. Implements docs/MESHSITES.md §5 — the same spec the
/// Python server passes 128 tests against. Also exposes localGET/localPOST
/// so the creator's Preview exercises the exact serving logic, radio aside.
@MainActor
final class MeshsiteServer: ObservableObject {
    static let shared = MeshsiteServer()

    static var serving: Bool { UserDefaults.standard.bool(forKey: "meshsiteServing") }
    static var siteName: String { UserDefaults.standard.string(forKey: "meshsiteName") ?? "" }

    static let chunkDataBytes = 190
    static let maxChunks = 16
    static let protocolVersion: UInt8 = 1   // both our min and max today

    @Published private(set) var lastBeaconAt: Date?
    @Published private(set) var requestsServed = 0

    private struct CachedResponse {
        let request: [UInt8]
        let frames: [Data]
        let wantAck: Bool
        let at: Date
    }
    private var cache: [String: CachedResponse] = [:]   // "requester/id"
    private var active: [Int64: [UInt8]] = [:]          // requester → in-flight request
    private var ackWaiters: [UInt32: CheckedContinuation<Bool, Never>] = [:]
    private var beaconTimer: Timer?
    private var nextBeaconGap: TimeInterval = 300

    private init() {
        // Light cadence check; the real beacon interval is 300 s ± 30 s.
        beaconTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in MeshsiteServer.shared.tick() }
        }
    }

    // MARK: - Beacon

    private func tick() {
        guard MeshsitesManager.enabled, Self.serving else { return }
        MeshsiteStore.shared.startIfNeeded()
        guard !Self.siteName.isEmpty, RadioManager.shared.state == .connected else { return }
        if let last = lastBeaconAt, Date().timeIntervalSince(last) < nextBeaconGap { return }
        sendBeacon()
    }

    /// Called when the serve toggle or site name changes — beacons promptly.
    func servingDidChange() {
        lastBeaconAt = nil
        tick()
    }

    private func sendBeacon() {
        // Spec §2: no control/bidi characters on the air.
        var name = MeshsitesManager.sanitizeDisplay(Self.siteName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 40 { name.removeLast() }
        guard !name.isEmpty else { return }
        var frame = Data([0x01, 0x01])
        frame.append(Data(name.utf8))
        RadioManager.shared.sendMeshsites(to: Int64(UInt32.max), payload: frame, wantAck: false)
        lastBeaconAt = Date()
        // 285 ± 15 so the 15 s tick granularity still lands within the
        // spec's 300 ± 30 s window.
        nextBeaconGap = 285 + .random(in: -15...15)
    }

    // MARK: - Acks (routing results forwarded by RadioManager)

    func noteAck(requestId: UInt32, ok: Bool = true) {
        ackWaiters.removeValue(forKey: requestId)?.resume(returning: ok)
    }

    /// Chunk pacing: resolve on the packet's routing result or after 8 s.
    /// Returns false on a transport NAK — the peer is unreachable, so the
    /// caller aborts the remaining chunks instead of blasting them out.
    private func awaitAck(packetId: UInt32) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ackWaiters[packetId] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                await MainActor.run { self?.ackWaiters.removeValue(forKey: packetId)?.resume(returning: true) }
            }
        }
    }

    // MARK: - Requests

    func handleRequest(from: Int64, bytes: [UInt8]) {
        guard MeshsitesManager.enabled, Self.serving else { return }
        MeshsiteStore.shared.startIfNeeded()
        guard bytes.count >= 4 else { return }   // id unparseable → silent
        let version = bytes[1]
        let id = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        // Spec §7: client below our minimum version → ERROR 6.
        guard version >= Self.protocolVersion else {
            sendError(to: from, id: id, code: 6, message: "Requires Meshsites protocol v1")
            return
        }
        guard bytes.count >= 11 else { sendError(to: from, id: id, code: 3); return }
        let method = bytes[4]
        let reqEtag = UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16
                    | UInt32(bytes[7]) << 8 | UInt32(bytes[8])
        let pathLen = Int(bytes[9])
        guard id != 0, method <= 1, pathLen > 0, pathLen <= 120,
              bytes.count >= 10 + pathLen,
              let path = String(bytes: bytes[10..<(10 + pathLen)], encoding: .utf8),
              path.hasPrefix("/") else {
            sendError(to: from, id: id, code: 3)
            return
        }
        let body = bytes.count > 10 + pathLen ? Array(bytes[(10 + pathLen)...]) : []
        guard method == 1 || body.isEmpty else {   // GET with body (spec §2)
            sendError(to: from, id: id, code: 3)
            return
        }
        // POST etag is ignored (§2) — normalize it to 0 before keying the
        // caches so an etag-varying POST retry still hits (§3).
        var bytes = bytes
        if method == 1 { bytes[5] = 0; bytes[6] = 0; bytes[7] = 0; bytes[8] = 0 }

        // Single-flight per requester (spec §3): identical duplicate of the
        // in-flight request is a link-level retransmit — drop silently.
        if let inFlight = active[from] {
            if inFlight == bytes { return }
            sendError(to: from, id: id, code: 5)
            return
        }
        // Response cache, keyed by full request content (spec §3).
        let key = "\(from)/\(id)"
        if let cached = cache[key], Date().timeIntervalSince(cached.at) < 120 {
            if cached.request == bytes {
                active[from] = bytes
                Task {
                    await sendFrames(cached.frames, to: from, wantAck: cached.wantAck)
                    active[from] = nil
                }
                return
            }
            cache[key] = nil   // same id, different content — render fresh
        }

        active[from] = bytes
        Task {
            await serve(from: from, id: id, method: method, reqEtag: reqEtag,
                        path: path, body: body, requestBytes: bytes, key: key)
            active[from] = nil
        }
    }

    private func serve(from: Int64, id: UInt16, method: UInt8, reqEtag: UInt32,
                       path: String, body: [UInt8], requestBytes: [UInt8], key: String) async {
        let store = MeshsiteStore.shared
        guard store.ready else {
            // Never claim a POST was recorded before the store can record it.
            sendError(to: from, id: id, code: 4, message: "Server is starting — try again")
            return
        }
        let markdown: String
        if method == 0 {
            switch await store.pageContentAsync(requestPath: path) {
            case .notFound:
                sendError(to: from, id: id, code: 1)
                return
            case .badRequest:
                sendError(to: from, id: id, code: 3)
                return
            case .syncing:
                sendError(to: from, id: id, code: 4, message: "Page is syncing — try again")
                return
            case .found(let md):
                markdown = md
            }
        } else {
            let fields = Self.parseForm(body)
            let recorded = await store.appendSubmissionAsync(
                fromLabel: String(format: "!%08x", UInt32(truncatingIfNeeded: from)),
                path: path, fields: fields)
            guard recorded else {
                sendError(to: from, id: id, code: 4, message: "Server is starting — try again")
                return
            }
            if case .found(let md) = await store.pageContentAsync(requestPath: path) {
                markdown = md
            } else {
                markdown = Self.thanksPage
            }
        }

        let source = Data(markdown.utf8)
        let etag = MeshsitesWire.fnv1a(source)
        if method == 0, reqEtag == etag {
            let frame = Data([0x05, UInt8(id >> 8), UInt8(id & 0xFF),
                              UInt8(etag >> 24 & 0xFF), UInt8(etag >> 16 & 0xFF),
                              UInt8(etag >> 8 & 0xFF), UInt8(etag & 0xFF)])
            cache[key] = CachedResponse(request: requestBytes, frames: [frame],
                                        wantAck: true, at: Date())
            pruneCache()
            await sendFrames([frame], to: from, wantAck: true)
            requestsServed += 1
            return
        }

        let compressed = MeshsitesWire.deflate(source)
        guard !compressed.isEmpty,
              compressed.count <= Self.chunkDataBytes * Self.maxChunks else {
            sendError(to: from, id: id, code: 2)
            return
        }
        let total = (compressed.count + Self.chunkDataBytes - 1) / Self.chunkDataBytes
        var frames: [Data] = []
        for seq in 0..<total {
            let start = seq * Self.chunkDataBytes
            let end = min(start + Self.chunkDataBytes, compressed.count)
            var frame = Data([0x03, Self.protocolVersion,
                              UInt8(id >> 8), UInt8(id & 0xFF),
                              UInt8(seq), UInt8(total),
                              UInt8(etag >> 24 & 0xFF), UInt8(etag >> 16 & 0xFF),
                              UInt8(etag >> 8 & 0xFF), UInt8(etag & 0xFF)])
            frame.append(compressed.subdata(in: start..<end))
            frames.append(frame)
        }
        cache[key] = CachedResponse(request: requestBytes, frames: frames,
                                    wantAck: true, at: Date())
        pruneCache()
        await sendFrames(frames, to: from, wantAck: true)
        requestsServed += 1
    }

    private func sendFrames(_ frames: [Data], to requester: Int64, wantAck: Bool) async {
        for (index, frame) in frames.enumerated() {
            let packetId = RadioManager.shared.sendMeshsites(to: requester, payload: frame,
                                                             wantAck: wantAck)
            // Pace: chunk n+1 after n's ack or 8 s; nothing after the last.
            // A NAK means the peer is gone — stop wasting airtime.
            if wantAck, index < frames.count - 1 {
                guard await awaitAck(packetId: packetId) else { return }
            }
        }
    }

    private func sendError(to requester: Int64, id: UInt16, code: UInt8, message: String = "") {
        var frame = Data([0x04, UInt8(id >> 8), UInt8(id & 0xFF), code])
        if !message.isEmpty {
            // Trim to 120 bytes on a UTF-8 boundary so the client can decode.
            var bytes = Array(message.utf8.prefix(120))
            while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            frame.append(Data(bytes))
        }
        RadioManager.shared.sendMeshsites(to: requester, payload: frame, wantAck: false)
    }

    private func pruneCache() {
        let cutoff = Date().addingTimeInterval(-120)
        cache = cache.filter { $0.value.at > cutoff }
        while cache.count > 64, let oldest = cache.min(by: { $0.value.at < $1.value.at }) {
            cache[oldest.key] = nil
        }
    }

    static func parseForm(_ body: [UInt8]) -> [(String, String)] {
        guard let text = String(bytes: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let rawName = parts.first, !rawName.isEmpty else { return nil }
            let value = parts.count > 1
                ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                    ?? String(parts[1]))
                : ""
            return (String(rawName), value)
        }
    }

    static let thanksPage = "# Thanks!\n\nYour reply was recorded.\n\n=> / Home\n"

    // MARK: - Local rendering (creator Preview runs the real serving logic)

    func localGET(_ path: String) -> String {
        MeshsiteStore.shared.startIfNeeded()
        switch MeshsiteStore.shared.pageContent(requestPath: path) {
        case .found(let md): return md
        case .syncing:
            return "# Syncing\n\nThis page hasn't downloaded from iCloud yet.\n\n=> / Home\n"
        case .notFound:
            return "# Not found\n\nNo page at \(path) — readers will get “Page not found.”\n\n=> / Home\n"
        case .badRequest:
            return "# Bad link\n\n\(path) isn't a valid page path.\n\n=> / Home\n"
        }
    }

    func localPOST(_ path: String, fields: [(String, String)]) -> String {
        MeshsiteStore.shared.appendSubmission(fromLabel: "preview", path: path, fields: fields)
        if case .found(let md) = MeshsiteStore.shared.pageContent(requestPath: path) { return md }
        return Self.thanksPage
    }
}
#endif
