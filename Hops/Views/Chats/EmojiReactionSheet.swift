import SwiftUI

/// Any-emoji reaction picker: a grid of common choices plus a text field that
/// accepts anything the emoji keyboard can type. Reactions are permanent on
/// mesh — the protocol has no retraction — hence the footer note.
struct EmojiReactionSheet: View {
    var onPick: (String) -> Void

    @State private var typed = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let common = [
        "❤️", "👍", "👎", "🤣", "‼️", "❓", "🎉", "🔥",
        "👋", "🙏", "😢", "😮", "💯", "🫡", "📍", "⛺️",
        "🚴", "🥾", "☀️", "🌧️", "⚡️", "🔋", "📡", "🐇",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                    ForEach(Self.common, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                        } label: {
                            Text(emoji).font(.title2)
                        }
                    }
                }
                .padding(.horizontal)

                TextField("Or type any emoji…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .padding(.horizontal)
                    .onChange(of: typed) { _, newValue in
                        guard let first = newValue.first else { return }
                        onPick(String(first))
                    }

                Text("Reactions can't be removed on mesh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
