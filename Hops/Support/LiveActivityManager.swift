import Foundation
import ActivityKit

/// Runs the delivery Live Activity for outgoing DMs.
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    private var activities: [Int64: Activity<SendActivityAttributes>] = [:]
    private var channelSends: Set<Int64> = []

    func start(packetId: Int64, peerName: String, preview: String, isChannel: Bool = false) {
        if isChannel { channelSends.insert(packetId) }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SendActivityAttributes(peerName: peerName,
                                                preview: String(preview.prefix(50)))
        let state = SendActivityAttributes.ContentState(statusText: "Sending…", phase: 0)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
        guard let activity = try? Activity.request(attributes: attributes, content: content) else { return }
        activities[packetId] = activity
        // Safety net: never leave a stuck activity behind.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(240))
            await self?.finish(packetId: packetId, status: "No response yet", phase: 3, ifStillRunning: true)
        }
    }

    /// Channel broadcasts terminate on the implicit ack ("Sent to mesh").
    func isChannelSend(_ packetId: Int64) -> Bool { channelSends.contains(packetId) }

    func update(packetId: Int64, status: String, phase: Int, final isFinal: Bool) {
        guard activities[packetId] != nil else { return }
        if isFinal {
            Task { await finish(packetId: packetId, status: status, phase: phase, ifStillRunning: false) }
        } else {
            guard let activity = activities[packetId] else { return }
            let state = SendActivityAttributes.ContentState(statusText: status, phase: phase)
            Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))) }
        }
    }

    private func finish(packetId: Int64, status: String, phase: Int, ifStillRunning: Bool) async {
        guard let activity = activities[packetId] else { return }
        activities[packetId] = nil
        channelSends.remove(packetId)
        let state = SendActivityAttributes.ContentState(statusText: status, phase: phase)
        // Linger briefly so the final state is seen, then dismiss.
        await activity.end(ActivityContent(state: state, staleDate: nil),
                           dismissalPolicy: .after(Date().addingTimeInterval(4)))
    }
}
