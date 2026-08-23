import SwiftUI

/// Searchable any-emoji reaction picker. One field does both jobs: typed letters
/// search the full emoji set by Unicode name; a typed emoji (via the emoji
/// keyboard) sends immediately. Only emoji can ever be sent — plain letters
/// can't become reactions. Mesh reactions are permanent, hence the footer.
struct EmojiReactionSheet: View {
    var onPick: (String) -> Void

    @State private var query = ""
    @State private var allEmoji: [EmojiItem] = []
    @Environment(\.dismiss) private var dismiss

    struct EmojiItem: Identifiable {
        let id = UUID()
        let emoji: String
        let name: String
    }

    private static let common = [
        "❤️", "👍", "👎", "🤣", "‼️", "❓", "🎉", "🔥",
        "👋", "🙏", "😢", "😮", "💯", "🫡", "📍", "⛺️",
        "🚴", "🥾", "☀️", "🌧️", "⚡️", "🔋", "📡", "🐇",
    ]

    private var results: [EmojiItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allEmoji }
        return allEmoji.filter { $0.name.contains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Search emoji, or type one…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .padding(.horizontal)
                    .onChange(of: query) { _, newValue in
                        // An emoji typed from the emoji keyboard sends right away.
                        if let emojiChar = newValue.first(where: { $0.isEmojiLike }) {
                            onPick(String(emojiChar))
                        }
                    }

                ScrollView {
                    if query.isEmpty {
                        grid(Self.common.map { EmojiItem(emoji: $0, name: "") }, title: "Common")
                    }
                    if allEmoji.isEmpty {
                        ProgressView().padding()
                    } else if results.isEmpty {
                        Text("No emoji match “\(query)”")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        grid(results, title: query.isEmpty ? "All Emoji" : "Results")
                    }
                    Text("Reactions can't be removed on mesh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }
            .padding(.top, 12)
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if allEmoji.isEmpty {
                    allEmoji = await Task.detached(priority: .userInitiated) {
                        Self.buildEmojiList()
                    }.value
                }
            }
        }
    }

    private func grid(_ items: [EmojiItem], title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                ForEach(items) { item in
                    Button {
                        onPick(item.emoji)
                    } label: {
                        Text(item.emoji).font(.title2)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    /// Enumerate the emoji blocks and pair each glyph with its lowercase Unicode
    /// name for search. ~1300 entries; built once off the main thread.
    nonisolated private static func buildEmojiList() -> [EmojiItem] {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F,  // smileys
            0x1F900...0x1F9FF,  // supplemental symbols & people
            0x1FA70...0x1FAFF,  // extended-A
            0x1F440...0x1F4FF,  // people/objects slice of misc block
            0x1F300...0x1F43F,  // weather/nature/animals
            0x1F500...0x1F5FF,  // symbols
            0x1F680...0x1F6FF,  // transport
            0x2600...0x26FF,    // misc symbols
            0x2700...0x27BF,    // dingbats
        ]
        var items: [EmojiItem] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji else { continue }
                // Non-default presentation (e.g. ☀) needs the variation selector.
                let emoji = scalar.properties.isEmojiPresentation
                    ? String(scalar)
                    : String(scalar) + "\u{FE0F}"
                guard !emoji.isEmpty else { continue }
                let name = String(scalar).applyingTransform(StringTransform("Any-Name"), reverse: false)?
                    .replacingOccurrences(of: "\\N{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .lowercased() ?? ""
                items.append(EmojiItem(emoji: emoji, name: name))
            }
        }
        return items
    }
}

extension Character {
    /// True for characters that render as emoji (what's allowed as a reaction).
    var isEmojiLike: Bool {
        guard let first = unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        if unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return true }
        return first.properties.isEmoji && first.value >= 0x1F000
    }
}
