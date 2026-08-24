import WidgetKit
import SwiftUI
import ActivityKit

@main
struct HopsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SendLiveActivity()
    }
}

/// The drama of a mesh send: Sending… → Relayed → Delivered to their radio.
struct SendLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SendActivityAttributes.self) { context in
            LockScreenSendView(context: context)
                .padding(14)
                .activityBackgroundTint(Color(red: 0.16, green: 0.17, blue: 0.18))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.peerName)
                            .font(.subheadline.weight(.semibold))
                        Text(context.state.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            } compactTrailing: {
                PhaseIcon(phase: context.state.phase)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

struct PhaseIcon: View {
    let phase: Int

    var body: some View {
        switch phase {
        case 1:
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.cyan)
        case 2:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case 3:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        default:
            Image(systemName: "dot.radiowaves.right")
                .foregroundStyle(.secondary)
        }
    }
}

struct LockScreenSendView: View {
    let context: ActivityViewContext<SendActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            PhaseIcon(phase: context.state.phase)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.peerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(context.attributes.preview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Text(context.state.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.trailing)
        }
    }
}
