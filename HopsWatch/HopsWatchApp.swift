import SwiftUI
import SwiftData

/// Hops on the wrist (TODO 217): the same iCloud store as the phone, its own
/// Bluetooth link to the radio. Modeled on Messages: conversations, then a
/// thread with a compose field.
@main
struct HopsWatchApp: App {
    let container: ModelContainer
    @StateObject private var radio = WatchRadio.shared

    init() {
        let schema = Schema([ConversationEntity.self, MessageEntity.self, NodeEntity.self,
                             ChannelEntity.self, WaypointEntity.self, PositionSampleEntity.self,
                             CoverageSampleEntity.self, SeqTrackEntity.self, RadioEntity.self,
                             GameSessionEntity.self])
        do {
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
        WatchRadio.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ConversationsView()
            }
            .environmentObject(radio)
        }
        .modelContainer(container)
    }
}
