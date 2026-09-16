import SwiftUI
import SwiftData

/// One conversation: bubbles, newest at the bottom, and a compose field.
/// The watch keyboard offers dictation and scribble on its own.
struct ThreadView: View {
    let conversation: ConversationEntity
    @Query private var messages: [MessageEntity]
    @Query private var nodes: [NodeEntity]
    @EnvironmentObject private var radio: WatchRadio
    @State private var draft = ""

    init(conversation: ConversationEntity) {
        self.conversation = conversation
        let key = conversation.key
        _messages = Query(filter: #Predicate<MessageEntity> { $0.conversationKey == key && $0.portNum == 1 },
                          sort: \MessageEntity.timestamp)
    }

    private var destination: MessageDestinationRef {
        conversation.kind == .channel ? .channel(conversation.channelIndex) : .node(conversation.peerNum)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages.suffix(60)) { message in
                    bubble(message)
                        .listRowBackground(Color.clear)
                        .id(message.packetId)
                }
                composeRow
                    .listRowBackground(Color.clear)
                    .id("compose")
            }
            .listStyle(.plain)
            .onAppear {
                radio.markRead(conversation.key)
                if let last = messages.last { proxy.scrollTo(last.packetId, anchor: .bottom) }
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.packetId, anchor: .bottom) } }
            }
        }
        .navigationTitle(conversation.title.isEmpty ? "Conversation" : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bubble(_ message: MessageEntity) -> some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
            if !message.outgoing, conversation.kind == .channel {
                Text(senderName(message.fromNum))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(message.outgoing ? Color.accentColor : Color(white: 0.22),
                            in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            Text(statusLine(message))
                .font(.system(size: 10))
                .foregroundStyle(message.status == .failed ? .red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
    }

    private var composeRow: some View {
        VStack(spacing: 6) {
            TextField("Message", text: $draft)
                .textInputAutocapitalization(.sentences)
                .onSubmit(send)
            HStack {
                ForEach(["👍", "OK", "On my way"], id: \.self) { quick in
                    Button(quick) { radio.sendText(quick, to: destination) }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
            }
            if radio.state != .connected {
                Text("Not connected to a radio; sends wait in the outbox.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        radio.sendText(text, to: destination)
        draft = ""
    }

    private func senderName(_ num: Int64) -> String {
        nodes.first { $0.num == num }?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: num))
    }

    private func statusLine(_ message: MessageEntity) -> String {
        let time = message.timestamp.formatted(date: .omitted, time: .shortened)
        guard message.outgoing else { return time }
        switch message.status {
        case .waitingForRadio: return "Waiting for radio"
        case .sending: return "Sending…"
        case .relayed: return "Relayed"
        case .deliveredToRadio: return "Delivered"
        case .sentToMesh: return "Sent"
        case .failed: return "Not delivered"
        case .waitingForPeer: return "Waiting for them"
        default: return time
        }
    }
}
