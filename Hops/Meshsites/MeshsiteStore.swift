#if MESHSITES
import Foundation

/// File layer for the user's own Meshsite. Pages are plain .md files in
/// iCloud Drive (container Documents/Meshsite — visible in the Files app as
/// Hops › Meshsite, editable from any device), falling back to local
/// Documents when iCloud is unavailable. Names starting with "_" are private
/// and never served; form submissions append to _replies.md.
///
/// Serving-path IO (page resolution, submission appends) runs detached —
/// NSFileCoordinator can block for seconds mid-iCloud-sync and must never
/// stall the main actor, where BLE handling and chunk pacing live.
@MainActor
final class MeshsiteStore: ObservableObject {
    static let shared = MeshsiteStore()

    nonisolated static let maxCompressedBytes = 3056   // spec: 16 chunks × 191
    nonisolated static let maxSubmissionsBytes = 128 * 1024

    struct PageInfo: Identifiable, Equatable {
        let name: String        // "index"
        let url: URL
        var size: Int           // source bytes
        var title: String
        var downloaded: Bool
        var id: String { name }
        var path: String { name == "index" ? "/" : "/" + name }
    }

    enum ServeLookup {
        case found(String)
        case notFound
        case badRequest        // traversal, bad encoding, malformed path
        case syncing           // exists in iCloud, not materialized here yet
    }

    @Published private(set) var pages: [PageInfo] = []
    @Published private(set) var usingICloud = false
    @Published private(set) var ready = false
    @Published private(set) var submissionCount = 0

    private var root: URL?
    private var starting = false
    private var repliesURL: URL? { root?.appendingPathComponent("_replies.md") }

    // MARK: - Startup

    func startIfNeeded() {
        guard !ready, !starting else { return }
        start()
    }

    func start() {
        if ready { refresh(); return }
        guard !starting else { return }
        starting = true
        Task.detached { [weak self] in
            // url(forUbiquityContainerIdentifier:) can block — off main.
            let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            let base: URL
            let icloud: Bool
            if let container {
                base = container.appendingPathComponent("Documents/Meshsite", isDirectory: true)
                icloud = true
            } else {
                base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Meshsite", isDirectory: true)
                icloud = false
            }
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.root = base
                self.usingICloud = icloud
                self.ready = true
                self.starting = false
                self.refresh()
                // Starter pages only into a genuinely empty site — and on
                // iCloud, give cloud metadata a moment to appear first so a
                // fresh install doesn't stomp a site synced from elsewhere.
                Task { [weak self] in
                    if icloud { try? await Task.sleep(for: .seconds(8)) }
                    self?.ensureStarterPages()
                }
            }
        }
    }

    /// First run gets a small teaching site: home, a working guestbook form,
    /// and the thanks page the form points at.
    private func ensureStarterPages() {
        guard let root else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let hasContent = existing.contains { $0.hasSuffix(".md") || $0.hasSuffix(".icloud") }
        guard !hasContent else { refresh(); return }
        Self.coordWrite(root.appendingPathComponent("index.md"), Data("""
        # My Meshsite

        Welcome! This page is served straight from my radio — no internet.

        * Edit these pages in Hops › Settings › Meshsites › Mesh Site
        * Or in iCloud Drive › Hops › Meshsite from any device

        => /guestbook Sign my guestbook

        ---
        Served by Hops
        """.utf8))
        Self.coordWrite(root.appendingPathComponent("guestbook.md"), Data("""
        # Guestbook

        Leave a note — it lands in my Form Replies.

        [form post /thanks]
        [field name Your name]
        [field note A short note]
        [submit Sign]
        [/form]

        => / Home
        """.utf8))
        Self.coordWrite(root.appendingPathComponent("thanks.md"), Data("""
        # Thanks!

        Your note was recorded.

        => / Home
        """.utf8))
        refresh()
    }

    // MARK: - Listing

    func refresh() {
        guard let root = root, let replies = repliesURL else { return }
        Task.detached { [weak self] in
            let infos = Self.listPages(root: root)
            let count = Self.countSubmissions(in: Self.readText(replies) ?? "")
            await MainActor.run { [weak self] in
                self?.pages = infos
                self?.submissionCount = count
            }
        }
    }

    nonisolated private static func listPages(root: URL) -> [PageInfo] {
        let fm = FileManager.default
        var infos: [PageInfo] = []
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in items {
            let file = url.lastPathComponent
            if file.hasPrefix("."), file.hasSuffix(".icloud") {
                // Undownloaded iCloud item: ".name.md.icloud" — request it.
                let inner = String(file.dropFirst().dropLast(".icloud".count))
                guard inner.hasSuffix(".md"), !inner.hasPrefix("_") else { continue }
                let name = String(inner.dropLast(3))
                let target = root.appendingPathComponent(inner)
                try? fm.startDownloadingUbiquitousItem(at: target)
                infos.append(PageInfo(name: name, url: target, size: 0,
                                      title: name, downloaded: false))
            } else if file.hasSuffix(".md"), !file.hasPrefix("_"), !file.hasPrefix(".") {
                let name = String(file.dropLast(3))
                let content = readText(url) ?? ""
                infos.append(PageInfo(name: name, url: url, size: content.utf8.count,
                                      title: title(of: content, fallback: name),
                                      downloaded: true))
            }
        }
        infos.sort { a, b in
            if a.name == "index" { return true }
            if b.name == "index" { return false }
            return a.name < b.name
        }
        return infos
    }

    nonisolated private static func title(of content: String, fallback: String) -> String {
        for line in content.split(separator: "\n") where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return fallback
    }

    // MARK: - Page IO (editor-facing; user-initiated, tiny files)

    func read(page name: String) -> String? {
        guard let root else { return nil }
        return Self.readText(root.appendingPathComponent(name + ".md"))
    }

    func write(page name: String, content: String) {
        guard let root else { return }
        Self.coordWrite(root.appendingPathComponent(name + ".md"), Data(content.utf8))
        refresh()
    }

    func create(page name: String) {
        guard let root else { return }
        let content = "# \(name)\n\nWrite something here.\n\n=> / Home\n"
        Self.coordWrite(root.appendingPathComponent(name + ".md"), Data(content.utf8))
        refresh()
    }

    func delete(page name: String) {
        guard let root, name != "index" else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name + ".md"))
        refresh()
    }

    nonisolated static func isValidPageName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_") && name.utf8.count <= 100
            && name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Serving-path resolution

    /// Resolves a wire request path to page content. Percent-decodes, strips
    /// any query, distinguishes bad requests (traversal, malformed) from
    /// unknown pages, rejects the private "_" namespace, and treats empty
    /// files as not-a-page (spec §5).
    nonisolated static func resolve(root: URL, requestPath: String) -> ServeLookup {
        var path = requestPath
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        guard let decoded = path.removingPercentEncoding,
              decoded.hasPrefix("/") else { return .badRequest }
        guard !decoded.contains("..") else { return .badRequest }
        var name = String(decoded.dropFirst())
        if name.hasSuffix("/") { name = String(name.dropLast()) }
        if name.isEmpty { name = "index" }
        guard isValidPageName(name) else { return .notFound }
        let url = root.appendingPathComponent(name + ".md")
        if let text = readText(url) {
            return text.isEmpty ? .notFound : .found(text)
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".\(name).md.icloud").path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .syncing
        }
        return .notFound
    }

    /// Synchronous variant for the in-app Preview.
    func pageContent(requestPath: String) -> ServeLookup {
        guard ready, let root else { return .syncing }
        return Self.resolve(root: root, requestPath: requestPath)
    }

    /// Radio-serving variant: file IO runs detached so a syncing iCloud file
    /// can never stall the main actor.
    func pageContentAsync(requestPath: String) async -> ServeLookup {
        guard ready, let root else { return .syncing }
        return await Task.detached { Self.resolve(root: root, requestPath: requestPath) }.value
    }

    // MARK: - Form submissions ("all form input is saved to a file")

    nonisolated private static func oneLine(_ text: String) -> String {
        // Newlines and controls could forge "## " entry headers in the file.
        String(text.map { $0.isNewline || ($0.isASCII && $0.asciiValue! < 0x20) ? " " : $0 })
    }

    nonisolated static func appendEntry(url: URL, fromLabel: String, path: String,
                                        fields: [(String, String)]) -> Int {
        var text = readText(url) ?? ""
        let stamp = stampFormatter.string(from: Date())
        var entry = "## \(stamp) — \(oneLine(fromLabel)) → \(oneLine(path))\n\n"
        if fields.isEmpty {
            entry += "* (no fields)\n"
        } else {
            for (name, value) in fields {
                entry += "* \(oneLine(name)): \(oneLine(value))\n"
            }
        }
        entry += "\n"
        text += entry
        // Bound the file: drop oldest entries past the cap.
        while text.utf8.count > maxSubmissionsBytes,
              let next = text.range(of: "\n## ", range: text.index(after: text.startIndex)..<text.endIndex) {
            text = String(text[text.index(after: next.lowerBound)...])
        }
        coordWrite(url, Data(text.utf8))
        return countSubmissions(in: text)
    }

    /// Synchronous variant for the in-app Preview.
    func appendSubmission(fromLabel: String, path: String, fields: [(String, String)]) {
        guard ready, let url = repliesURL else { return }
        submissionCount = Self.appendEntry(url: url, fromLabel: fromLabel, path: path, fields: fields)
    }

    /// Radio-serving variant, off-main. Returns false if the store isn't
    /// ready — the caller must NOT claim the submission was recorded.
    func appendSubmissionAsync(fromLabel: String, path: String,
                               fields: [(String, String)]) async -> Bool {
        guard ready, let url = repliesURL else { return false }
        let count = await Task.detached {
            Self.appendEntry(url: url, fromLabel: fromLabel, path: path, fields: fields)
        }.value
        submissionCount = count
        return true
    }

    func submissionsText() -> String {
        guard let url = repliesURL else { return "" }
        return Self.readText(url) ?? ""
    }

    func clearSubmissions() {
        guard let url = repliesURL else { return }
        try? FileManager.default.removeItem(at: url)
        submissionCount = 0
    }

    nonisolated private static func countSubmissions(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = text.hasPrefix("## ") ? 1 : 0
        var search = text.startIndex
        while let r = text.range(of: "\n## ", range: search..<text.endIndex) {
            count += 1
            search = r.upperBound
        }
        return count
    }

    // MARK: - Coordinated IO (iCloud-safe)

    nonisolated private static func readText(_ url: URL) -> String? {
        coordRead(url).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated private static func coordRead(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            data = try? Data(contentsOf: u)
        }
        return data
    }

    nonisolated private static func coordWrite(_ url: URL, _ data: Data) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    nonisolated private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
#endif
