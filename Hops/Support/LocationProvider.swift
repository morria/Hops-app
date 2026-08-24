import Foundation
import CoreLocation

/// One-shot location fetches with proper authorization flow — the old inline
/// CLLocationManager read `.location` before permission or a fix existed.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Resolves with a location, or nil when denied/unavailable.
    func current() async -> CLLocation? {
        // A recent fix is good enough for sharing.
        if let cached = manager.location, cached.timestamp > Date().addingTimeInterval(-60) {
            return cached
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // didChangeAuthorization continues the flow.
        default:
            manager.requestLocation()
        }
        if continuation != nil { return manager.location }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func resume(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.resume(locations.first) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.continuation != nil { manager.requestLocation() }
            case .denied, .restricted:
                self.resume(nil)
            default:
                break
            }
        }
    }
}
