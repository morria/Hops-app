import Foundation
import CoreBluetooth
import MeshtasticProtobufs
@testable import Hops

/// Scripted stand-in for BLECentral: records every call, lets a test push
/// events and FromRadio frames as if radios were talking.
final class MockTransport: RadioTransport {
    var onEvent: (@MainActor (BLECentral.Event) -> Void)?
    var activated = false
    var scanning = false
    var wanted: Set<UUID> = []
    var forgotten: [UUID] = []
    var writes: [(id: UUID, data: Data)] = []

    func activate() { activated = true }
    func startScan() { scanning = true }
    func stopScan() { scanning = false }
    func connect(to ids: Set<UUID>) { wanted.formUnion(ids) }
    func forget(_ id: UUID) { wanted.remove(id); forgotten.append(id) }
    func retryFresh(id: UUID) {}
    func connectDiscovered(id: UUID) { wanted.insert(id) }
    func disconnect(id: UUID, userInitiated: Bool) {}
    func disconnectAll(userInitiated: Bool) {}
    func write(id: UUID, _ data: Data) { writes.append((id, data)) }
    func drain(id: UUID) {}

    @MainActor func emit(_ event: BLECentral.Event) { onEvent?(event) }

    /// Decoded ToRadio packets written to `id`, in order.
    func packets(to id: UUID) -> [ToRadio] {
        writes.filter { $0.id == id }.compactMap { try? ToRadio(serializedBytes: $0.data) }
    }
}
