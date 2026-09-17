import AppIntents
import SwiftData
import Foundation

/// Focus filter (iOS Settings › Focus › <focus> › Add Filter › Hops): per
/// Focus, choose which mesh conversations may notify. The system calls
/// `perform` when a Focus with this filter turns on; the choice is cached
/// and consulted on every inbound message. When no filtering Focus is
/// active, `FocusFilterState.current` is nil and everything behaves as
/// before (TODO 220).
struct HopsFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Hops Notifications"
    static var description = IntentDescription("Choose which mesh conversations can notify you while this Focus is on.")

    @Parameter(title: "Direct messages", default: true)
    var allowDirectMessages: Bool

    @Parameter(title: "Only pinned conversations", default: false)
    var onlyPinned: Bool

    /// Empty = every channel; otherwise only these.
    @Parameter(title: "Channels", default: [])
    var channels: [FocusChannel]

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        parts.append(allowDirectMessages ? "DMs on" : "DMs off")
        parts.append(channels.isEmpty ? "all channels" : channels.map(\.name).joined(separator: ", "))
        if onlyPinned { parts.append("pinned only") }
        return DisplayRepresentation(title: "Hops", subtitle: LocalizedStringResource(stringLiteral: parts.joined(separator: " · ")))
    }

    func perform() async throws -> some IntentResult {
        FocusFilterState.save(FocusFilterState(allowDirectMessages: allowDirectMessages, onlyPinned: onlyPinned,
                                               channelIndexes: Set(channels.map { Int32($0.id) })))
        return .result()
    }
}

/// A channel as Focus's picker sees it.
struct FocusChannel: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Channel")
    static var defaultQuery = FocusChannelQuery()

    var id: Int
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
}

struct FocusChannelQuery: EntityQuery {
    @MainActor
    private func all() -> [FocusChannel] {
        guard let container = ModelContainerHolder.container else { return [] }
        var d = FetchDescriptor<ChannelEntity>()
        d.sortBy = [SortDescriptor(\.index)]
        let rows = (try? container.mainContext.fetch(d)) ?? []
        return rows.filter(\.isActive).map { FocusChannel(id: Int($0.index), name: $0.displayName) }
    }
    func entities(for identifiers: [Int]) async throws -> [FocusChannel] {
        await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [FocusChannel] { await all() }
}

/// The active filter, cached for the notification path. Refreshed from the
/// system on foreground so a Focus turned off while Hops slept is noticed.
struct FocusFilterState: Codable {
    var allowDirectMessages: Bool
    var onlyPinned: Bool
    var channelIndexes: Set<Int32>

    private static let key = "focusFilterState"

    static var current: FocusFilterState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FocusFilterState.self, from: data)
    }

    static func save(_ state: FocusFilterState?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Ask the system which filter (if any) is active right now.
    static func refresh() async {
        if let intent = try? await HopsFocusFilter.current {
            save(FocusFilterState(allowDirectMessages: intent.allowDirectMessages, onlyPinned: intent.onlyPinned,
                                  channelIndexes: Set(intent.channels.map { Int32($0.id) })))
        } else {
            save(nil)
        }
    }

    /// Does this message get through the active filter?
    func allows(isDM: Bool, channelIndex: Int32?, pinned: Bool) -> Bool {
        if onlyPinned, !pinned { return false }
        if isDM { return allowDirectMessages }
        guard let channelIndex else { return true }
        return channelIndexes.isEmpty || channelIndexes.contains(channelIndex)
    }
}

/// The app's model container, for intents that run in-process.
@MainActor
enum ModelContainerHolder {
    static var container: ModelContainer?
}
