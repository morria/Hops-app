import ActivityKit
import Foundation

/// Live Activity payload for a DM in flight across the mesh.
struct SendActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        /// 0 sending, 1 relayed, 2 delivered, 3 failed
        var phase: Int
    }

    var peerName: String
    var preview: String
}
