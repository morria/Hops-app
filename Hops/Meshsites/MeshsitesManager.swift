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

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "meshsitesEnabled") }

    struct Site: Identifiable, Equatable {
        let id: Int64        // node num
        var name: String
        var lastHeard: Date
    }

    @Published private(set) var sites: [Site] = []
    @Published private(set) var progress: (received: Int, total: Int)?

    enum SiteError: LocalizedError {
        case notConnected
        case timeout
        case requestTooLarge
        case badResponse
        case requestInFlight
        case server(code: UInt8, message: String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to a radio."
            case .timeout: return "No response — the site's radio may be out of range."
            case .requestTooLarge: return "Form input is too long to send over the mesh."
            case .badResponse: return "The site sent an unreadable response."
            case .requestInFlight: return "Still loading the previous page."
            case .server(let code, let message):
                if !message.isEmpty { return message }
                switch code {
                case 1: return "Page not found."
                case 2: return "The page is too large for the mesh."
                case 3: return "The site rejected the request."
                case 5: return "The site is busy — try again in a moment."
                default: return "The site reported an error."
                }
            }
        }
    }

    private struct Pending {
        let server: Int64
        var chunks: [Int: Data] = [:]
        var total: Int?
        var cacheKey: CacheKey?
        var continuation: CheckedContinuation<String, Error>
        var timeoutTask: Task<Void, Never>?
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
            if to == RadioManager.shared.myNodeNum {
                MeshsiteServer.shared.handleRequest(from: from, bytes: bytes)
            }
        case 0x03: handleChunk(from: from, bytes: bytes)
        case 0x04: handleError(from: from, bytes: bytes)
        case 0x05: handleNotModified(from: from, bytes: bytes)
        default: break   // spec §1: ignore unknown frame types
        }
    }

    private func handleBeacon(from: Int64, bytes: [UInt8]) {
        guard from != RadioManager.shared.myNodeNum else { return }  // our own site
        guard bytes.count >= 3, bytes[1] >= 1 else { return }
        let nameBytes = bytes[2...]
        guard nameBytes.count <= 40,
              let name = String(bytes: nameBytes, encoding: .utf8),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let index = sites.firstIndex(where: { $0.id == from }) {
            sites[index].name = name
            sites[index].lastHeard = Date()
        } else {
            sites.append(Site(id: from, name: name, lastHeard: Date()))
        }
        // Sort every update — a rename must re-place the site.
        sites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-20 * 60)
        sites.removeAll { $0.lastHeard < cutoff }
    }

    /// Looks up the pending entry for a response frame, enforcing that the
    /// frame came from the node the request was addressed to (spec §3).
    private func pendingEntry(id: UInt16, from: Int64) -> Pending? {
        guard let entry = pending[id], entry.server == from else { return nil }
        return entry
    }

    private func handleChunk(from: Int64, bytes: [UInt8]) {
        guard bytes.count >= 9 else { return }
        let id = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        let seq = Int(bytes[3])
        let total = Int(bytes[4])
        let etag = UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16
                 | UInt32(bytes[7]) << 8 | UInt32(bytes[8])
        guard var entry = pendingEntry(id: id, from: from),
              (1...16).contains(total), seq < total else { return }
        if let known = entry.total, known != total { return }
        entry.total = total
        entry.chunks[seq] = bytes.count > 9 ? Data(bytes[9...]) : Data()
        pending[id] = entry
        restartTimeout(id: id)
        if progressId == nil || progressId == id {
            progressId = id
            progress = (entry.chunks.count, total)
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
                pageCache[key] = CacheEntry(etag: etag, markdown: markdown, fetchedAt: Date())
            }
            finish(id: id, with: .success(markdown))
        }
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
        finish(id: id, with: .success(cached.markdown))
    }

    private func finish(id: UInt16, with result: Result<String, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        if progressId == id {
            progressId = nil
            progress = nil
        }
        entry.continuation.resume(with: result)
    }

    private func restartTimeout(id: UInt16) {
        pending[id]?.timeoutTask?.cancel()
        pending[id]?.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.finish(id: id, with: .failure(SiteError.timeout))
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
               policy: CachePolicy = .revalidate) async throws -> String {
        let frameBody = try Self.buildRequestBody(path: path, post: post, form: form)
        let cacheKey: CacheKey? = post ? nil
            : CacheKey(server: server, path: String(decoding: frameBody.path, as: UTF8.self))

        if let cacheKey, policy == .cacheFirst, let entry = freshEntry(cacheKey) {
            return entry.markdown
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
                                                server: server, cacheKey: cacheKey, id: id)
            } catch SiteError.timeout where attempt == 1 {
                continue   // spec §3: one retry, same id
            }
        }
    }

    private func performRequest(frameBody: (method: UInt8, path: Data, body: Data),
                                etag: UInt32, server: Int64,
                                cacheKey: CacheKey?, id: UInt16) async throws -> String {
        var frame = Data([0x02, UInt8(id >> 8), UInt8(id & 0xFF), frameBody.method,
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
                RadioManager.shared.sendMeshsites(to: server, payload: frame)
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
    /// until the request fits one packet (spec §2, 9-byte header). Throws if
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
            if pathData.count <= maxPathBytes, 9 + pathData.count + bodyData.count <= maxFrameBytes {
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
