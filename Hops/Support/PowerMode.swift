import Foundation

/// Battery Saver: user toggle OR the system's Low Power Mode — either engages
/// the reduced-cost behaviors (no coverage sampling, no Live Activities,
/// slower map refresh, no scan-assist).
enum PowerMode {
    static var saver: Bool {
        UserDefaults.standard.bool(forKey: "batterySaver")
            || ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
