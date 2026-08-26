#if MESHSITES
import SwiftUI
import SwiftData

/// Nearby Meshsites, alphabetical. Sites appear passively as beacons are
/// heard and expire 20 minutes after the last one. Rows wear the serving
/// node's avatar (short name / icon), same as conversations.
struct MeshsitesListView: View {
    @ObservedObject private var manager = MeshsitesManager.shared
    @AppStorage("meshsiteName") private var mySiteName = ""
    @AppStorage("meshsiteServing") private var serving = false
    @Environment(\.modelContext) private var modelContext
    @State private var now = Date()

    private struct NodeAvatar {
        let monogram: String
        let iconData: Data?
    }
    @State private var avatars: [Int64: NodeAvatar] = [:]

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private func refreshAvatars() {
        var ids = manager.sites.map(\.id)
        ids.append(RadioManager.shared.myNodeNum)
        let descriptor = FetchDescriptor<NodeEntity>(predicate: #Predicate { ids.contains($0.num) })
        let nodes = (try? modelContext.fetch(descriptor)) ?? []
        avatars = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.num, NodeAvatar(monogram: $0.monogram, iconData: $0.iconData))
        })
    }

    private func avatar(for num: Int64, fallback name: String) -> some View {
        MonogramAvatar(text: avatars[num]?.monogram ?? String(name.prefix(4)),
                       isChannel: false, size: 36,
                       imageData: avatars[num]?.iconData)
    }

    var body: some View {
        List {
            // Your own site, when it's on the air. Opens through the real
            // serving engine locally — an RF round trip to yourself isn't a
            // thing, and this is the same content readers get.
            if serving, !mySiteName.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    NavigationLink {
                        MeshsitePreviewView(startPath: "/")
                    } label: {
                        HStack(spacing: 12) {
                            avatar(for: RadioManager.shared.myNodeNum, fallback: mySiteName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mySiteName)
                                Text("This phone — served by you")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if manager.sites.isEmpty {
                ContentUnavailableView {
                    Label("No sites nearby", systemImage: "globe")
                } description: {
                    Text("Sites appear when a node within direct radio range broadcasts one.")
                }
            } else {
                ForEach(manager.sites) { site in
                    if site.deprecated {
                        // Spec §6: retired protocol versions surface as
                        // outdated, not broken — and aren't browsable.
                        HStack(spacing: 12) {
                            avatar(for: site.id, fallback: site.name)
                                .opacity(0.45)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name)
                                    .foregroundStyle(.secondary)
                                Text("This site's server is too old for this version of Hops.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        NavigationLink {
                            MeshsiteBrowserView(site: site)
                        } label: {
                            HStack(spacing: 12) {
                                avatar(for: site.id, fallback: site.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.name)
                                    Text("Heard \(site.lastHeard, style: .relative) ago")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sites")
        .onAppear {
            manager.pruneExpired()
            refreshAvatars()
        }
        .onChange(of: manager.sites) { _, _ in refreshAvatars() }
        .onReceive(ticker) { date in
            now = date
            manager.pruneExpired()
        }
    }
}

/// Renders a parsed Meshdown document — used identically by the reader
/// browser and the creator's site preview, so what creators see is exactly
/// what readers get. Owns form field state; navigation and submission are
/// the caller's business.
struct MeshdownRenderer: View {
    let document: MeshdownDocument
    var disabled = false
    let onNavigate: (String) -> Void
    let onSubmit: (MeshdownDocument.Form, [(String, String)]) -> Void

    @State private var formValues: [String: String] = [:]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(document.items) { item in
                blockView(item)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ item: MeshdownDocument.Item) -> some View {
        switch item.block {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline)
                .padding(.top, item.id == 0 ? 0 : 4)
        case .paragraph(let text):
            Text(text)
        case .listItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(text)
            }
        case .rule:
            Divider()
        case .link(let path, let label):
            Button {
                onNavigate(path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle")
                    Text(label)
                        .multilineTextAlignment(.leading)
                }
            }
            .disabled(disabled)
        case .form(let form):
            formView(form, itemId: item.id)
        }
    }

    private func formView(_ form: MeshdownDocument.Form, itemId: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(form.fields, id: \.name) { field in
                TextField(field.label, text: binding(itemId: itemId, field: field.name))
                    .textFieldStyle(.roundedBorder)
            }
            Button(form.submitLabel) {
                let pairs = form.fields.map { ($0.name, formValues["\(itemId).\($0.name)"] ?? "") }
                onSubmit(form, pairs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func binding(itemId: Int, field: String) -> Binding<String> {
        let key = "\(itemId).\(field)"
        return Binding(
            get: { formValues[key] ?? "" },
            set: { formValues[key] = $0 }
        )
    }
}

/// Renders one remote site: fetches Meshdown pages, follows links, submits
/// forms.
struct MeshsiteBrowserView: View {
    let site: MeshsitesManager.Site

    @ObservedObject private var manager = MeshsitesManager.shared
    @State private var history: [String] = ["/"]
    @State private var document: MeshdownDocument?
    @State private var loading = false
    @State private var errorText: String?
    @State private var resetToken = 0
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    if let progress = manager.progress {
                        Text("Receiving \(progress.received) of \(progress.total)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Requesting over the mesh — this takes a moment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                ContentUnavailableView {
                    Label("Couldn't load page", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("Try Again") { reload() }
                        .buttonStyle(.borderedProminent)
                }
            } else if let document {
                ScrollView {
                    MeshdownRenderer(document: document, disabled: loading,
                                     onNavigate: { navigate(to: $0) },
                                     onSubmit: { form, pairs in submit(form, pairs: pairs) })
                        .id(resetToken)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if history.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        history.removeLast()
                        // Back nav is served straight from cache when possible
                        // (spec §3.5) — instant, zero airtime.
                        startLoad(history.last ?? "/", policy: .cacheFirst)
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(loading)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .task { startLoad(history.last ?? "/") }
        .onDisappear { loadTask?.cancel() }
    }

    // MARK: - Loading

    private func reload() {
        startLoad(history.last ?? "/")
    }

    private func navigate(to path: String) {
        history.append(path)
        startLoad(path)
    }

    private func startLoad(_ path: String, post: Bool = false, form: [(String, String)] = [],
                           policy: MeshsitesManager.CachePolicy = .revalidate) {
        loadTask?.cancel()
        loadTask = Task { await load(path, post: post, form: form, policy: policy) }
    }

    private func load(_ path: String, post: Bool = false, form: [(String, String)] = [],
                      policy: MeshsitesManager.CachePolicy = .revalidate) async {
        loading = true
        errorText = nil
        do {
            let page = try await manager.fetch(path, from: site.id, post: post,
                                               form: form, policy: policy)
            guard !Task.isCancelled else { return }
            document = MeshdownDocument.parse(page.markdown, version: page.version)
            resetToken += 1
        } catch is CancellationError {
            return   // dismissed or superseded — a newer load owns the state
        } catch {
            guard !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func submit(_ form: MeshdownDocument.Form, pairs: [(String, String)]) {
        if form.isPost {
            // POST renders the response; back/refresh re-GETs the path.
            history.append(form.path)
            startLoad(form.path, post: true, form: pairs)
        } else {
            // GET forms bake the (truncated-to-fit) query into history so
            // refresh replays it.
            do {
                navigate(to: try MeshsitesManager.getPath(form.path, form: pairs))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
#endif
