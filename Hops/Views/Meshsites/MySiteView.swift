#if MESHSITES
import SwiftUI

/// The creator's home: name the site, flip it on the air, manage pages,
/// read form replies, preview exactly what readers will see.
struct MySiteView: View {
    @ObservedObject private var store = MeshsiteStore.shared
    @ObservedObject private var server = MeshsiteServer.shared
    @ObservedObject private var radio = RadioManager.shared
    @AppStorage("meshsiteName") private var siteName = ""
    @AppStorage("meshsiteServing") private var serving = false

    @State private var showNewPage = false
    @State private var newPageName = ""

    var body: some View {
        Form {
            siteSection
            pagesSection
            extrasSection
        }
        .navigationTitle("My Site")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.start() }
        .alert("New Page", isPresented: $showNewPage) {
            TextField("page-name", text: $newPageName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") { createPage() }
            Button("Cancel", role: .cancel) { newPageName = "" }
        } message: {
            Text("Lowercase letters, numbers, and dashes. Reachable at /page-name.")
        }
    }

    private var siteSection: some View {
        Section {
            TextField("Site name (what visitors see)", text: $siteName)
                .onChange(of: siteName) { _, new in
                    var trimmed = new
                    while trimmed.utf8.count > 40 { trimmed.removeLast() }
                    if trimmed != new { siteName = trimmed }
                    // No beacon here — the next regular beacon (≤5 min)
                    // announces the new name. Beaconing per keystroke would
                    // spam RF with every partial name.
                }
            Toggle("Serve My Site", isOn: $serving)
                .disabled(siteName.trimmingCharacters(in: .whitespaces).isEmpty)
                .onChange(of: serving) { _, _ in server.servingDidChange() }
            if serving {
                if radio.state == .connected {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("On the air", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Group {
                            if let at = server.lastBeaconAt {
                                Text("Last beacon \(at, style: .relative) ago · every ~5 min")
                            }
                            if server.requestsServed > 0 {
                                Text("\(server.requestsServed) pages served this session")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Paused — radio disconnected", systemImage: "pause.circle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Site")
        } footer: {
            Text("Visitors within direct radio range of your node can browse these pages. Nothing is relayed through the mesh.")
        }
    }

    private var pagesSection: some View {
        Section {
            ForEach(store.pages) { page in
                NavigationLink {
                    PageEditorView(page: page)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title)
                            Text(page.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if page.downloaded {
                            Text("\(page.size) B")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet where store.pages[index].name != "index" {
                    store.delete(page: store.pages[index].name)
                }
            }
            Button {
                newPageName = ""
                showNewPage = true
            } label: {
                Label("New Page", systemImage: "plus")
            }
        } header: {
            Text("Pages")
        } footer: {
            if store.usingICloud {
                Text("Files live in iCloud Drive › Hops › Meshsite — edit them from any device. Names starting with “_” are private and never served.")
            } else {
                Text("iCloud is unavailable — pages are stored only on this device.")
            }
        }
    }

    private var extrasSection: some View {
        Section {
            NavigationLink {
                MeshsiteRepliesView()
            } label: {
                Label("Form Replies", systemImage: "tray.full")
                    .badge(store.submissionCount)
            }
            NavigationLink {
                MeshsitePreviewView(startPath: "/")
            } label: {
                Label("Preview Site", systemImage: "eye")
            }
        } footer: {
            Text("Preview uses the exact pages and forms readers get, minus the radio round trip.")
        }
    }

    private func createPage() {
        let slug = newPageName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" || $0 == "_" }
        newPageName = ""
        guard MeshsiteStore.isValidPageName(slug),
              !store.pages.contains(where: { $0.name == slug }) else { return }
        store.create(page: slug)
    }
}

/// Markdown editor with the gauge that matters: live compressed size against
/// the 3,056-byte wire budget.
struct PageEditorView: View {
    let page: MeshsiteStore.PageInfo

    @ObservedObject private var store = MeshsiteStore.shared
    @State private var text = ""
    @State private var originalText = ""
    @State private var loaded = false
    @State private var loadAttempts = 0
    @State private var loadFailed = false
    @State private var compressedBytes = 0
    @State private var saveTask: Task<Void, Never>?

    private var overBudget: Bool { compressedBytes > MeshsiteStore.maxCompressedBytes }

    var body: some View {
        Group {
            if loaded {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 10)
                    .safeAreaInset(edge: .bottom) { gauge }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Not downloaded", systemImage: "icloud.slash")
                } description: {
                    Text("This page hasn't synced from iCloud yet. Check your connection and try again.")
                } actions: {
                    Button("Try Again") {
                        loadAttempts = 0
                        loadFailed = false
                        attemptLoad()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Downloading from iCloud…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(page.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { insertMenu.disabled(!loaded) }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MeshsitePreviewView(startPath: page.path)
                } label: {
                    Image(systemName: "eye")
                }
                .disabled(!loaded)
            }
        }
        .onAppear { attemptLoad() }
        .onChange(of: text) { _, _ in
            guard loaded else { return }
            updateGauge()
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                store.write(page: page.name, content: text)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            // Write only after a successful read AND a real change — never
            // stomp an undownloaded iCloud page with an empty file, never
            // resurrect a page deleted elsewhere by closing an idle editor.
            if loaded, text != originalText {
                store.write(page: page.name, content: text)
            }
        }
    }

    /// The file may be an undownloaded iCloud placeholder — poll for the
    /// download (refresh() triggers it) instead of treating a failed read
    /// as an empty page.
    private func attemptLoad() {
        guard !loaded else { return }
        if let content = store.read(page: page.name) {
            text = content
            originalText = content
            loaded = true
            updateGauge()
            return
        }
        store.refresh()   // kicks startDownloadingUbiquitousItem
        loadAttempts += 1
        if loadAttempts >= 20 {
            loadFailed = true
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            attemptLoad()
        }
    }

    private var gauge: some View {
        HStack(spacing: 6) {
            Image(systemName: overBudget ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
            if text.isEmpty {
                Text("Empty — this page won't be served")
            } else if overBudget {
                Text("Too big to serve — trim \(compressedBytes - MeshsiteStore.maxCompressedBytes) compressed bytes")
            } else {
                Text("\(compressedBytes) of \(MeshsiteStore.maxCompressedBytes) bytes on the wire")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(overBudget ? .red : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var insertMenu: some View {
        Menu {
            Menu("Link to Page") {
                ForEach(store.pages) { target in
                    Button("\(target.title) (\(target.path))") {
                        append("\n=> \(target.path) \(target.title)\n")
                    }
                }
            }
            Button("Form") {
                append("\n[form post /thanks]\n[field name Your name]\n[submit Send]\n[/form]\n")
            }
            Button("Heading") { append("\n## Heading\n") }
            Button("Divider") { append("\n---\n") }
        } label: {
            Image(systemName: "plus.circle")
        }
    }

    private func append(_ snippet: String) {
        text += snippet
    }

    private func updateGauge() {
        compressedBytes = MeshsitesWire.deflate(Data(text.utf8)).count
    }
}

/// Every form submission, newest at the bottom, as the plain file readers of
/// _replies.md would see on any device.
struct MeshsiteRepliesView: View {
    @ObservedObject private var store = MeshsiteStore.shared
    @State private var text = ""
    @State private var confirmClear = false

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView {
                    Label("No replies yet", systemImage: "tray")
                } description: {
                    Text("When a visitor submits a form on your site, it lands here — and in iCloud Drive › Hops › Meshsite › _replies.md.")
                }
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("Form Replies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !text.isEmpty {
                Button("Clear") { confirmClear = true }
            }
        }
        .confirmationDialog("Delete all form replies?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                store.clearSubmissions()
                text = ""
            }
        }
        .onAppear { text = store.submissionsText() }
    }
}

/// Browses the local site through the real serving logic (localGET/localPOST)
/// — links navigate, forms submit (marked "preview" in replies), and every
/// page renders with the same MeshdownRenderer readers get.
struct MeshsitePreviewView: View {
    let startPath: String

    @State private var history: [String] = []
    @State private var document: MeshdownDocument?
    @State private var resetToken = 0

    var body: some View {
        Group {
            if let document {
                ScrollView {
                    MeshdownRenderer(document: document,
                                     onNavigate: { open($0) },
                                     onSubmit: { form, pairs in submit(form, pairs: pairs) })
                        .id(resetToken)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if history.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        history.removeLast()
                        render(history.last ?? "/")
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                }
            }
        }
        .onAppear {
            guard history.isEmpty else { return }
            history = [startPath]
            render(startPath)
        }
    }

    private func render(_ path: String) {
        document = MeshdownDocument.parse(MeshsiteServer.shared.localGET(path))
        resetToken += 1
    }

    private func open(_ path: String) {
        history.append(path)
        render(path)
    }

    private func submit(_ form: MeshdownDocument.Form, pairs: [(String, String)]) {
        if form.isPost {
            history.append(form.path)
            document = MeshdownDocument.parse(MeshsiteServer.shared.localPOST(form.path, fields: pairs))
            resetToken += 1
        } else {
            let path = (try? MeshsitesManager.getPath(form.path, form: pairs)) ?? form.path
            open(path)
        }
    }
}
#endif
