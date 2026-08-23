import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var radio: RadioManager
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        TabView(selection: $appModel.selectedTab) {
            ChatsListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)
            MapTab()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .fullScreenCover(isPresented: .constant(radio.state == .noRadio)) {
            PairingView()
        }
        .sheet(isPresented: $radio.needsMeshSetup) {
            NavigationStack {
                MeshSetupView(isFirstRun: true)
            }
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Status capsule

/// The thin connection-state banner. Quietly absent when all is well.
struct StatusCapsule: View {
    @EnvironmentObject private var radio: RadioManager

    var body: some View {
        if let text = statusText {
            HStack(spacing: 6) {
                if radio.state == .connecting || radio.state == .syncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(text)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var statusText: String? {
        switch radio.state {
        case .connected: return nil
        case .connecting: return "Connecting…"
        case .syncing: return catchingUp ? "Catching up — last synced \(lastSyncText)" : "Syncing…"
        case .offline: return "Radio not in range"
        case .bluetoothOff: return "Bluetooth is off"
        case .bondLost: return "Radio needs re-pairing"
        case .noRadio: return nil
        }
    }

    private var icon: String {
        switch radio.state {
        case .bluetoothOff: return "antenna.radiowaves.left.and.right.slash"
        case .bondLost: return "exclamationmark.triangle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var catchingUp: Bool {
        guard let last = radio.lastSyncedAt else { return false }
        return Date().timeIntervalSince(last) > 60 * 60
    }

    private var lastSyncText: String {
        guard let last = radio.lastSyncedAt else { return "a while ago" }
        return last.formatted(.relative(presentation: .named))
    }
}

// MARK: - Shared avatar

struct MonogramAvatar: View {
    let text: String
    let isChannel: Bool
    var size: CGFloat = 44
    var dimmed: Bool = false
    var assetImage: String? = nil

    var body: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .background(.white)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                .opacity(dimmed ? 0.45 : 1)
        } else {
            monogramBody
        }
    }

    private var monogramBody: some View {
        ZStack {
            Circle()
                .fill(isChannel
                      ? AnyShapeStyle(Color.accentColor.gradient)
                      : AnyShapeStyle(Color(hue: hue, saturation: 0.45, brightness: 0.75).gradient))
            if isChannel {
                Image(systemName: "number")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(text)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.45 : 1)
    }

    private var hue: Double {
        let value = text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double(value % 360) / 360
    }
}
