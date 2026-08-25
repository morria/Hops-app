import SwiftUI

/// Long-press → Delivery Details: what actually happened to a message, in
/// plain language — what the current status proves (and doesn't), why a
/// failure failed, and the raw identifiers for cross-referencing the Mesh
/// Traffic log.
struct DeliveryDetailsView: View {
    let message: MessageEntity
    let isDM: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.title2)
                            .foregroundStyle(statusColor)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.headline)
                            Text(statusExplanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if message.status == .failed {
                    Section("Why it failed") {
                        Text(failureReason)
                            .font(.subheadline)
                    }
                }

                Section("Details") {
                    LabeledContent(message.outgoing ? "Sent" : "Received",
                                   value: message.timestamp.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Delivery", value: isDM ? "Direct message" : "Channel broadcast")
                    LabeledContent("Packet ID",
                                   value: String(format: "0x%08X", UInt32(truncatingIfNeeded: message.packetId)))
                    if message.replyId > 0 {
                        LabeledContent("In reply to",
                                       value: String(format: "0x%08X", UInt32(truncatingIfNeeded: message.replyId)))
                    }
                } footer: {
                    Text("The packet ID matches entries in Settings › Mesh traffic, if you want to trace the raw packets.")
                }

                Section {
                    Text(isDM
                         ? "How direct delivery works: your radio hands the message to nearby nodes, which rebroadcast it hop by hop until the destination radio hears it and sends an acknowledgment back along the mesh. Acknowledgments travel the same unreliable path — a missing ack doesn't always mean a missing message."
                         : "How channel delivery works: the message is broadcast hop by hop to everyone sharing the channel key. Broadcasts carry no per-person receipts, so \"Sent to mesh\" is the strongest confirmation a channel message can have.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Delivery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Status semantics

    private var statusTitle: String {
        switch message.status {
        case .received: return "Received"
        case .waitingForRadio: return "Waiting for your radio"
        case .waitingForPeer: return "Waiting for their radio"
        case .sending: return "Sending"
        case .relayed: return "Relayed by the mesh"
        case .deliveredToRadio: return "Delivered to their radio"
        case .sentToMesh: return "Sent to mesh"
        case .failed: return "Not confirmed"
        }
    }

    private var statusExplanation: String {
        switch message.status {
        case .received:
            return "Your radio heard this message over the mesh."
        case .waitingForRadio:
            return "Queued on this phone. It transmits the moment your radio reconnects."
        case .waitingForPeer:
            return "Held until their radio is next heard on the mesh, then sent automatically."
        case .sending:
            return "Transmitted by your radio. Waiting for the mesh to confirm — this can take a few minutes over long paths."
        case .relayed:
            return "Another node rebroadcast it, so it's traveling the mesh. Their radio hasn't confirmed receipt yet."
        case .deliveredToRadio:
            return "Their radio acknowledged receipt directly. It's on their device — this confirms delivery, not that they've read it."
        case .sentToMesh:
            return "Accepted onto the channel. Channel broadcasts don't carry per-person receipts, so this is full confirmation for a channel message."
        case .failed:
            return "The mesh couldn't confirm delivery before giving up."
        }
    }

    private var statusIcon: String {
        switch message.status {
        case .received: return "envelope.open"
        case .waitingForRadio: return "clock"
        case .waitingForPeer: return "clock.arrow.circlepath"
        case .sending: return "paperplane"
        case .relayed: return "arrow.triangle.branch"
        case .deliveredToRadio: return "checkmark.seal.fill"
        case .sentToMesh: return "dot.radiowaves.left.and.right"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch message.status {
        case .received, .deliveredToRadio, .sentToMesh: return .green
        case .relayed: return .mint
        case .waitingForRadio, .waitingForPeer: return .orange
        case .sending: return .secondary
        case .failed: return .red
        }
    }

    /// Routing.Error raw values (plus our -1 local-timeout sentinel), in words.
    private var failureReason: String {
        switch message.ackErrorRaw {
        case -1:
            return "No acknowledgment arrived before the timeout. The message may still have been delivered — acks get lost more often than messages do."
        case 1:
            return "No route to the destination was found."
        case 2:
            return "The destination radio rejected the message (NAK)."
        case 3:
            return "The request timed out inside the mesh."
        case 5:
            return "Your radio gave up after its maximum retransmissions — nothing acknowledged the packet."
        case 6:
            return "The receiving side has no matching channel for this message."
        case 7:
            return "The message was too large for the mesh."
        case 8:
            return "The destination saw the request but sent no response."
        case 9:
            return "A radio on the path hit its regulatory duty-cycle limit."
        case 34, 35:
            return "Encryption keys don't match — the destination couldn't decrypt it. Their key may have changed."
        default:
            return "Routing error code \(message.ackErrorRaw)."
        }
    }
}
