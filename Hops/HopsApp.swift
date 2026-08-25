import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct HopsApp: App {

    static let refreshTaskId = "com.w2asm.hops.refresh"

    let container: ModelContainer
    @StateObject private var radio = RadioManager.shared
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let schema = Schema([ConversationEntity.self, MessageEntity.self, NodeEntity.self,
                             ChannelEntity.self, WaypointEntity.self, PositionSampleEntity.self,
                             CoverageSampleEntity.self])
        do {
            // iCloud-synced store: messages, nodes, conversations, custom icons
            // follow the user across devices. Falls back to local-only if the
            // CloudKit container is unavailable (no iCloud account, etc.).
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            container = try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            do {
                let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                container = try ModelContainer(for: schema, configurations: [local])
            } catch {
                fatalError("Could not create model container: \(error)")
            }
        }
        RadioManager.shared.configure(container: container)
        #if MESHSITES
        // Wake the site server so beacons and request handling run without
        // the user ever opening My Site.
        _ = MeshsiteServer.shared
        #endif
        // Existing installs that paired before guided onboarding existed skip it.
        if RadioManager.shared.pairedPeripheralId != nil,
           UserDefaults.standard.object(forKey: "onboardingComplete") == nil {
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
        }
        #if DEBUG
        if ScreenshotMode.isActive {
            ScreenshotMode.seedIfNeeded(container: container)
        } else {
            NotificationManager.shared.bootstrap()
        }
        #else
        NotificationManager.shared.bootstrap()
        #endif
        Self.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(radio)
                .environmentObject(appModel)
                .onAppear {
                    NotificationManager.shared.openConversation = { key in
                        appModel.openConversation(key)
                    }
                    #if DEBUG
                    if ScreenshotMode.isActive {
                        appModel.selectedTab = ScreenshotMode.initialTab
                    }
                    #endif
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIStateObserver.shared.isActive = true
                radio.appDidBecomeActive()
            case .background:
                UIStateObserver.shared.isActive = false
                Self.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }

    private static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleBackgroundRefresh()
            let work = Task { @MainActor in
                await RadioManager.shared.backgroundSync()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// Deep-link target set by notification taps and the map's Message button;
    /// consumed by ChatsListView. Setting it also flips to the Chats tab.
    @Published var pendingConversationKey: String?
    @Published var selectedTab: Int = 0

    func openConversation(_ key: String) {
        pendingConversationKey = key
        selectedTab = 0
    }
}
