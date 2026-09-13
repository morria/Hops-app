#if MESHSITES
import Foundation
import Compression

/// Meshsites client: passive site discovery from beacons, page fetches with
/// chunk reassembly and etag caching, form submission. Protocol in
/// docs/MESHSITES.md. All Meshsites traffic is direct-RF only (hop_limit 1
/// out, relayed frames discarded on receive), and response frames are only
/// accepted from the node the request was addressed to.
@MainActor
final class MeshsitesManager: ObservableObject {
    static let shared = MeshsitesManager()
    static let port = 421
    static let maxFrameBytes = 200
    static let maxPathBytes = 120
    static let maxPageBytes = 64 * 1024   // decompressed cap, inclusive (spec §6)
    static let protocolVersion: UInt8 = 1 // highest we speak (spec §7)
    nonisolated static let minServerVersion: UInt8 = 1 // beacons below this are deprecated
    static let maxSites = 100             // beacon senders are unauthenticated

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "meshsitesEnabled") }

    struct Site: Identifiable, Equatable {
        let id: Int64        // node num
        var name: String
        var version: UInt8
        var lastHeard: Date
        var deprecated: Bool { version < MeshsitesManager.minServerVersion }
    }

    /// A fetched page plus the protocol/format version it was served with —
    /// the renderer selects syntax rules by version (spec §7).
    struct Page: Equatable {
        let markdown: String
        let version: UInt8
    }

    @Published private(set) var sites: [Site] = []

    /// Live state of the fetch in flight (TODO 189): every packet out and
    /// back, byte counts as soon as the first chunk names the total, and a
    /// renderable prefix of the page rebuilt on each contiguous chunk.
    struct Transfer: Equatable {
        enum PacketState: Equatable {
            case pending            // not yet seen
            case sent               // handed to the radio
            case acked              // routing ACK from the peer
            case failed(Int32)      // routing NAK
            case received(Int)      // chunk bytes
        }
        var server: Int64
        var startedAt: Date
        var attempt: Int = 1
        var request: PacketState = .sent
        var chunks: [PacketState] = []          // sized once total is known
        var receivedBytes = 0                   // compressed, so far
        var expectedBytes: Int?                 // compressed, estimated from total
        var inflatedBytes = 0                   // page bytes decodable so far
        var partial: Page?                      // renderable prefix (whole lines)
        var complete = false
        var lastEventAt: Date

        var totalChunks: Int? { chunks.isEmpty ? nil : chunks.count }
        var receivedChunks: Int { chunks.filter { if case .received = $0 { return true }; return false }.count }
    }
    @Published private(set) var transfer: Transfer?

    /// Legacy shape kept for callers that only want a fraction.
    var progress: (received: Int, total: Int)? {
        guard let t = transfer, let total = t.totalChunks else { return nil }
        return (t.receivedChunks, total)
    }

    enum SiteError: LocalizedError {
        case notConnected
        case timeout
        case deadAir(String)   // timeout + what we know about where it died
        case requestTooLarge
        case badResponse
        case requestInFlight
        case server(code: UInt8, message: String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to a radio."
            case .timeout: return "No response - the site's radio may be out of range."
            case .deadAir(let diagnosis): return diagnosis
            case .requestTooLarge: return "Form input is too long to send over the mesh."
            case .badResponse: return "The site sent an unreadable response."
            case .requestInFlight: return "Still loading the previous page."
            case .server(let code, let message):
                let clean = MeshsitesManager.sanitizeDisplay(message)
                if !clean.isEmpty { return clean }
                switch code {
                case 1: return "Page not found."
                case 2: return "The page is too large for the mesh."
                case 3: return "The site rejected the request."
                case 5: return "The site is busy - try again in a moment."
                case 6: return "This site needs a newer version of Hops."
                default: return "The site reported an error."
                }
            }
        }
    }

    private struct Pending {
        let server: Int64
        var chunks: [Int: Data] = [:]
        var total: Int?
        var version: UInt8?
        var cacheKey: CacheKey?
        var continuation: CheckedContinuation<Page, Error>
        var timeoutTask: Task<Void, Never>?
        // Radio-level fate of the request packet (routing results by id).
        var requestPacketId: UInt32 = 0
        var transmitted = false
        var nakError: Int32 = 0

        /// What we can honestly say when the 45 s of silence runs out.
        var silenceDiagnosis: String {
            if nakError != 0 {
                return "Your radio couldn't deliver the request (routing error \(nakError)). The site's radio may be off or out of direct range."
            }
            if !transmitted {
                return "No confirmation the request ever left your radio. Check the connection to your radio and try again."
            }
            return "The request was transmitted, but the site never answered. Its server may be offline - or its radio can't decrypt requests from you (if its node card shows a key warning, use Reset Encryption Key)."
        }
    }
    private var pending: [UInt16: Pending] = [:]
    private var inFlightServers: Set<Int64> = []
    private var progressId: UInt16?

    // MARK: - Page cache (spec §3.5)

    enum CachePolicy {
        case revalidate   // send cached etag, accept NOT_MODIFIED
        case cacheFirst   // serve a fresh cache hit without any request (back nav)
    }

    private struct CacheKey: Hashable {
        let server: Int64
        let path: String   // path+query exactly as sent
    }
    private struct CacheEntry {
        let etag: UInt32
        let markdown: String
        let version: UInt8
        var fetchedAt: Date
    }
    private var pageCache: [CacheKey: CacheEntry] = [:]
    private let cacheLifetime: TimeInterval = 24 * 60 * 60

    private func freshEntry(_ key: CacheKey) -> CacheEntry? {
        guard let entry = pageCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < cacheLifetime else {
            pageCache[key] = nil
            return nil
        }
        return entry
    }

    // MARK: - Receive (called from RadioManager for every port-421 packet)

    func handle(from: Int64, to: Int64, payload: Data, hopStart: UInt32, hopLimit: UInt32) {
        guard Self.enabled else { return }
        // Spec §1: oversize frames are malformed; relayed frames are discarded
        // — Meshsites is direct RF only.
        guard payload.count <= Self.maxFrameBytes else { return }
        if hopStart > 0 && hopLimit < hopStart { return }
        let bytes = [UInt8](payload)
        guard let type = bytes.first else { return }
        switch type {
        case 0x01: handleBeacon(from: from, bytes: bytes)
        case 0x02:
            // Someone is requesting a page from OUR site (server side).
            if RadioManager.shared.isMine(to) {
                MeshsiteServer.shared.handleRequest(from: from, bytes: bytes, via: to)
            }
        case 0x03: handleChunk(from: from, bytes: bytes)
        case 0x04: handleError(from: from, bytes: bytes)
        case 0x05: handleNotModified(from: from, bytes: bytes)
        default: break   // spec §1: ignore unknown frame types
        }
    }

    private func handleBeacon(from: Int64, bytes: [UInt8]) {
        guard !RadioManager.shared.isMine(from) else { return }  // our own site
        guard bytes.count >= 3, bytes[1] >= 1 else { return }
        let nameBytes = bytes[2...]
        guard nameBytes.count <= 40,
              let raw = String(bytes: nameBytes, encoding: .utf8) else { return }
        // Untrusted RF input headed for the UI — strip controls/bidi tricks.
        let name = Self.sanitizeDisplay(raw)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let index = sites.firstIndex(where: { $0.id == from }) {
            sites[index].name = name
            sites[index].version = bytes[1]
            sites[index].lastHeard = Date()
        } else {
            sites.append(Site(id: from, name: name, version: bytes[1], lastHeard: Date()))
        }
        // Bound the list — beacon senders are unauthenticated (spec §6).
        while sites.count > Self.maxSites,
              let oldest = sites.min(by: { $0.lastHeard < $1.lastHeard }) {
            sites.removeAll { $0.id == oldest.id }
        }
        // Sort every update — a rename must re-place the site.
        sites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Strips control characters and bidirectional-override characters —
    /// applied to any RF-sourced string before it reaches the UI (spec §2).
    nonisolated static func sanitizeDisplay(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where scalar.properties.generalCategory != .control
            && !(0x202A...0x202E).contains(scalar.value)
            && !(0x2066...0x2069).contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    func pruneExpired() {
        // The 20-minute expiry (spec: ~4 missed beacons) may only count time
        // we could actually hear beacons. Disconnected — or connected less
        // than a full window — nothing can expire; a reconnect grants every
        // known site a fresh window to be heard again.
        let radio = RadioManager.shared
        guard radio.state == .connected else { return }
        let cutoff = Date().addingTimeInterval(-20 * 60)
        guard let connectedAt = radio.connectedAt, connectedAt < cutoff else { return }
        sites.removeAll { $0.lastHeard < cutoff }
    }

    /// Looks up the pending entry for a response frame, enforcing that the
    /// frame came from the node the request was addressed to (spec §3).
    /// A match also refreshes the site's liveness — page traffic proves the
    /// server is alive right now, so a stale beacon must not prune it out
    /// from under a successful fetch.
    private func pendingEntry(id: UInt16, from: Int64) -> Pending? {
        guard let entry = pending[id], entry.server == from else { return nil }
        if let index = sites.firstIndex(where: { $0.id == from }) {
            sites[index].lastHeard = Date()
        }
        return entry
    }

    private func handleChunk(from: Int64, bytes: [UInt8]) {
        guard bytes.count >= 10 else { return }
        let version = bytes[1]
        let id = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let seq = Int(bytes[4])
        let total = Int(bytes[5])
        let etag = UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16
                 | UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        // Spec §2: version 0 or above ours is not renderable — ignore.
        guard (1...Self.protocolVersion).contains(version) else { return }
        guard var entry = pendingEntry(id: id, from: from),
              (1...16).contains(total), seq < total else { return }
        if let known = entry.total, known != total { return }
        if let known = entry.version, known != version { return }
        entry.total = total
        entry.version = version
        let chunkData = bytes.count > 10 ? Data(bytes[10...]) : Data()
        entry.chunks[seq] = chunkData
        pending[id] = entry
        restartTimeout(id: id)
        if progressId == nil || progressId == id {
            progressId = id
            updateTransfer(for: entry, total: total, seq: seq, chunkBytes: chunkData.count, version: version)
        }

        if entry.chunks.count == total {
            var joined = Data()
            for index in 0..<total {
                guard let part = entry.chunks[index] else { return }
                joined.append(part)
            }
            guard let inflated = Self.inflate(joined),
                  let markdown = String(data: inflated, encoding: .utf8) else {
                finish(id: id, with: .failure(SiteError.badResponse))
                return
            }
            if let key = entry.cacheKey, etag != 0 {
                pageCache[key] = CacheEntry(etag: etag, markdown: markdown,
                                            version: version, fetchedAt: Date())
            }
            finish(id: id, with: .success(Page(markdown: markdown, version: version)))
        }
    }

    /// Rebuilds the live transfer after a chunk: packet strip, byte counts,
    /// and the page prefix that the contiguous chunks so far decode to.
    private func updateTransfer(for entry: Pending, total: Int, seq: Int, chunkBytes: Int, version: UInt8) {
        var t = transfer ?? Transfer(server: entry.server, startedAt: Date(), lastEventAt: Date())
        if t.chunks.count != total { t.chunks = Array(repeating: .pending, count: total) }
        t.chunks[seq] = .received(chunkBytes)
        t.receivedBytes = entry.chunks.values.reduce(0) { $0 + $1.count }
        // Spec: every chunk but the last carries 190 bytes, so the total is
        // knowable from the first packet, exactly once the last one lands.
        let lastKnown = entry.chunks[total - 1]?.count
        t.expectedBytes = (total - 1) * 190 + (lastKnown ?? 190)
        t.lastEventAt = Date()
        // Contiguous prefix from chunk 0 is a valid DEFLATE stream prefix.
        var joined = Data()
        var index = 0
        while let part = entry.chunks[index] { joined.append(part); index += 1 }
        if !joined.isEmpty, let inflated = Self.inflatePrefix(joined) {
            t.inflatedBytes = inflated.count
            let complete = index == total
            if let text = Self.utf8Prefix(inflated) {
                let usable = complete ? text : Self.wholeLines(text)
                if !usable.isEmpty { t.partial = Page(markdown: usable, version: version) }
            }
            t.complete = complete
        }
        transfer = t
    }

    /// Longest prefix that is valid UTF-8 (a chunk boundary can split a
    /// multi-byte character).
    static func utf8Prefix(_ data: Data) -> String? {
        for drop in 0...3 where drop < data.count {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return s }
        }
        return nil
    }

    /// Everything up to the last newline — the final line may be cut mid-way.
    static func wholeLines(_ text: String) -> String {
        guard let cut = text.lastIndex(of: "\n") else { return "" }
        return String(text[...cut])
    }

    private func handleError(from: Int64, bytes: [UInt8]) {
        guard bytes.count >= 4 else { return }
        let id = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        guard pendingEntry(id: id, from: from) != nil else { return }
        let message = bytes.count > 4
            ? (String(bytes: bytes[4...], encoding: .utf8) ?? "")
            : ""
        finish(id: id, with: .failure(SiteError.server(code: bytes[3], message: message)))
    }

    private func handleNotModified(from: Int64, bytes: [UInt8]) {
        guard bytes.count >= 7 else { return }
        let id = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        guard let entry = pendingEntry(id: id, from: from) else { return }
        // We only send an etag whose page we hold (spec §3.5), so a cache
        // miss here means the entry was evicted mid-flight — treat as bad.
        guard let key = entry.cacheKey, var cached = pageCache[key] else {
            finish(id: id, with: .failure(SiteError.badResponse))
            return
        }
        cached.fetchedAt = Date()
        pageCache[key] = cached
        finish(id: id, with: .success(Page(markdown: cached.markdown, version: cached.version)))
    }

    private func finish(id: UInt16, with result: Result<Page, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        if progressId == id {
            progressId = nil
            transfer = nil
        }
        entry.continuation.resume(with: result)
    }

    /// Routing results for OUR request packets — powers the timeout diagnosis
    /// (never left the radio vs transmitted-but-unanswered vs NAK).
    func noteRequestRouting(packetId: UInt32, errorRaw: Int32) {
        for (id, entry) in pending where entry.requestPacketId == packetId {
            if errorRaw == 0 {
                pending[id]?.transmitted = true
                if progressId == id || progressId == nil { transfer?.request = .acked; transfer?.lastEventAt = Date() }
            } else {
                pending[id]?.nakError = errorRaw
                if progressId == id || progressId == nil { transfer?.request = .failed(errorRaw); transfer?.lastEventAt = Date() }
            }
        }
    }

    private func restartTimeout(id: UInt16) {
        pending[id]?.timeoutTask?.cancel()
        pending[id]?.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            guard let self, let entry = self.pending[id] else { return }
            self.finish(id: id, with: .failure(SiteError.deadAir(entry.silenceDiagnosis)))
        }
    }

    // MARK: - Fetch

    /// GET or POST a page. `form` pairs become the query string (GET) or the
    /// urlencoded body (POST). GET responses are cached per path+query and
    /// revalidated by etag; `.cacheFirst` serves a fresh hit with no request
    /// at all. Retries once on timeout, reusing the id so the server's
    /// response cache can re-serve. Cancellation-aware: cancelling the
    /// calling task abandons the request immediately.
    func fetch(_ path: String, from server: Int64,
               post: Bool = false, form: [(String, String)] = [],
               policy: CachePolicy = .revalidate) async throws -> Page {
        let frameBody = try Self.buildRequestBody(path: path, post: post, form: form)
        let cacheKey: CacheKey? = post ? nil
            : CacheKey(server: server, path: String(decoding: frameBody.path, as: UTF8.self))

        if let cacheKey, policy == .cacheFirst, let entry = freshEntry(cacheKey) {
            return Page(markdown: entry.markdown, version: entry.version)
        }

        guard RadioManager.shared.state == .connected else { throw SiteError.notConnected }
        guard !inFlightServers.contains(server) else { throw SiteError.requestInFlight }
        inFlightServers.insert(server)
        defer { inFlightServers.remove(server) }

        let etag = cacheKey.flatMap { freshEntry($0)?.etag } ?? 0
        var id = UInt16.random(in: 1...UInt16.max)
        while pending[id] != nil { id = UInt16.random(in: 1...UInt16.max) }

        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                return try await performRequest(frameBody: frameBody, etag: etag,
                                                server: server, cacheKey: cacheKey, id: id,
                                                attempt: attempt)
            } catch let error as SiteError where attempt == 1 {
                switch error {
                case .timeout, .deadAir: continue   // spec §3: one retry, same id
                default: throw error
                }
            }
        }
    }

    private func performRequest(frameBody: (method: UInt8, path: Data, body: Data),
                                etag: UInt32, server: Int64,
                                cacheKey: CacheKey?, id: UInt16, attempt: Int = 1) async throws -> Page {
        var frame = Data([0x02, Self.protocolVersion,
                          UInt8(id >> 8), UInt8(id & 0xFF), frameBody.method,
                          UInt8(etag >> 24 & 0xFF), UInt8(etag >> 16 & 0xFF),
                          UInt8(etag >> 8 & 0xFF), UInt8(etag & 0xFF),
                          UInt8(frameBody.path.count)])
        frame.append(frameBody.path)
        frame.append(frameBody.body)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(server: server, cacheKey: cacheKey,
                                      continuation: continuation)
                restartTimeout(id: id)
                if progressId == nil || progressId == id {
                    progressId = id
                    transfer = Transfer(server: server, startedAt: Date(), attempt: attempt, lastEventAt: Date())
                }
                let packetId = RadioManager.shared.sendMeshsites(to: server, payload: frame)
                pending[id]?.requestPacketId = packetId
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, with: .failure(CancellationError()))
            }
        }
    }

    /// The final path+query a GET form submission will request, with values
    /// truncated to fit one packet — callers use it for history entries.
    static func getPath(_ path: String, form: [(String, String)]) throws -> String {
        let body = try buildRequestBody(path: path, post: false, form: form)
        return String(decoding: body.path, as: UTF8.self)
    }

    /// Builds (method, path+query bytes, body bytes), truncating form values
    /// until the request fits one packet (spec §2, 10-byte header). Throws if
    /// it can't fit.
    static func buildRequestBody(path: String, post: Bool,
                                 form: [(String, String)]) throws -> (method: UInt8, path: Data, body: Data) {
        var values = form.map { ($0.0, $0.1) }
        for _ in 0...(form.map { $0.1.count }.reduce(0, +) + 1) {
            let encoded = urlencode(values)
            // Spec §4: a form path may already carry a query — join with "&".
            let separator = path.contains("?") ? "&" : "?"
            let pathString = post || encoded.isEmpty ? path : path + separator + encoded
            let pathData = Data(pathString.utf8)
            let bodyData = post ? Data(encoded.utf8) : Data()
            if pathData.count <= maxPathBytes, 10 + pathData.count + bodyData.count <= maxFrameBytes {
                return (post ? 1 : 0, pathData, bodyData)
            }
            // Trim a character off the longest value and try again.
            guard let longest = values.indices.max(by: { values[$0].1.count < values[$1].1.count }),
                  !values[longest].1.isEmpty else { throw SiteError.requestTooLarge }
            values[longest].1 = String(values[longest].1.dropLast())
        }
        throw SiteError.requestTooLarge
    }

    static func urlencode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { name, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(v)"
        }.joined(separator: "&")
    }

    /// Raw DEFLATE (RFC 1951) — Apple's COMPRESSION_ZLIB is the headerless
    /// stream the spec requires. Cap is 64 KiB inclusive (spec §6); the
    /// buffer is one byte larger so exactly-64KiB pages are distinguishable
    /// from overflow.
    /// Decodes as much of a raw-DEFLATE stream as the bytes so far allow —
    /// a truncated stream yields a valid prefix of the page (TODO 189).
    static func inflatePrefix(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = maxPageBytes + 1
        var dst = [UInt8](repeating: 0, count: capacity)
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { out -> Int in
                stream.src_ptr = base
                stream.src_size = data.count
                stream.dst_ptr = out.baseAddress!
                stream.dst_size = capacity
                let status = compression_stream_process(&stream, 0)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { return 0 }
                return capacity - stream.dst_size
            }
        }
        guard written > 0, written <= maxPageBytes else { return nil }
        return Data(dst.prefix(written))
    }

    /// One line for Mesh Traffic per Meshsites frame.
    nonisolated static func describeFrame(_ bytes: [UInt8]) -> String {
        guard let type = bytes.first else { return "empty" }
        switch type {
        case 0x01: return "beacon \"\(String(bytes: bytes.dropFirst(2), encoding: .utf8) ?? "")\""
        case 0x02:
            guard bytes.count >= 10 else { return "request (malformed)" }
            let n = Int(bytes[9]); let path = bytes.count >= 10 + n ? String(bytes: bytes[10..<10 + n], encoding: .utf8) ?? "?" : "?"
            return "request \(bytes[4] == 1 ? "POST" : "GET") \(path)"
        case 0x03:
            guard bytes.count >= 10 else { return "chunk (malformed)" }
            return "chunk \(Int(bytes[4]) + 1)/\(bytes[5]) · \(max(0, bytes.count - 10)) B"
        case 0x04: return "error \(bytes.count > 3 ? Int(bytes[3]) : -1)"
        case 0x05: return "not modified"
        default: return "type \(type) · \(bytes.count) B"
        }
    }

    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = maxPageBytes + 1
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&dst, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written <= maxPageBytes else { return nil }
        return Data(dst.prefix(written))
    }
}
#endif
