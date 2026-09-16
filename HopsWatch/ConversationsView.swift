import SwiftUI
import SwiftData

/// First screen: every conversation, newest first, like Messages.
struct ConversationsView: View {
    @Query(sort: \ConversationEntity.lastMessageAt, order: .reverse) private var conversations: [ConversationEntity]
    @Query private var messages: [MessageEntity]
    @EnvironmentObject private var radio: WatchRadio

    private var visible: [ConversationEntity] {
        conversations.filter { $0.lastMessageAt != nil || $0.kind == .channel }
    }

    var body: some View {
        List {
            if radio.state != .connected {
                NavigationLink { RadioView() } label: { statusRow }
            }
            ForEach(visible) { convo in
                NavigationLink {
                    ThreadView(conversation: convo)
                } label: {
                    HStack(spacing: 8) {
                        MonogramView(text: convo.kind == .channel ? "#" : String(convo.title.prefix(2)).uppercased(),
                                     isChannel: convo.kind == .channel)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(convo.title.isEmpty ? "Conversation" : convo.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                if convo.unreadCount > 0 {
                                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                }
                            }
                            Text(preview(convo))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            if visible.isEmpty {
                Text("No conversations yet. They sync from your phone over iCloud, and arrive here once the watch is connected to a radio.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Hops")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { RadioView() } label: {
                    Image(systemName: radio.state == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(radio.state == .connected ? Color.accentColor : .secondary)
                }
            }
        }
    }

    private func preview(_ convo: ConversationEntity) -> String {
        let key = convo.key
        let last = messages.filter { $0.conversationKey == key && $0.portNum == 1 }
            .max { $0.timestamp < $1.timestamp }
        guard let last else { return convo.kind == .channel ? "Channel" : "No messages yet" }
        return (last.outgoing ? "You: " : "") + last.text
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
            Text(radio.hasRadio ? WatchRadio.statusText(radio.state) : "Pair a radio")
                .font(.caption)
        }
    }
}

extension WatchRadio {
    static func statusText(_ state: State) -> String {
        switch state {
        case .noRadio: return "No radio paired"
        case .bluetoothOff: return "Bluetooth is off"
        case .offline: return "Radio not in range"
        case .connecting: return "Connecting…"
        case .syncing: return "Syncing…"
        case .connected: return "Connected"
        }
    }
}

struct MonogramView: View {
    let text: String
    let isChannel: Bool
    var body: some View {
        ZStack {
            Circle().fill(isChannel ? Color.accentColor.gradient : Color(hue: hue, saturation: 0.45, brightness: 0.75).gradient)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }
    private var hue: Double {
        Double(text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360) / 360
    }
}
