import Foundation
import MeshtasticProtobufs

/// "Very low power" (TODO 195): every setting that makes the radio transmit
/// or draw power on its own, and the value that stops it. The toggle in
/// Device Configuration is *derived* — on only while every one of these is
/// in its recommended state, so any manual change switches it off.
enum LowPowerProfile {
    /// An interval the radio will never reach — the firmware's "off".
    static let never: UInt32 = 4_294_967_295
    /// Node info still goes out — every 4 hours (firmware floor is 1 h).
    static let nodeInfoSecs: UInt32 = 4 * 3600

    struct Check: Identifiable {
        let id: String
        let label: String
        let detail: String
        let satisfied: Bool
    }

    /// The whole checklist against the given state. `nil` module configs
    /// count as unknown (not satisfied) so the toggle can't claim a state
    /// the radio hasn't reported.
    static func checks(telemetry: ModuleConfig.TelemetryConfig?,
                       position: Config.PositionConfig?,
                       device: Config.DeviceConfig?,
                       modules: RadioManager.ModuleConfigs,
                       power: Config.PowerConfig? = nil,
                       display: Config.DisplayConfig? = nil,
                       network: Config.NetworkConfig? = nil) -> [Check] {
        var out: [Check] = []
        func add(_ id: String, _ label: String, _ detail: String, _ ok: Bool?) {
            out.append(Check(id: id, label: label, detail: detail, satisfied: ok ?? false))
        }
        add("devtel", "Battery & device telemetry off",
            "device_telemetry_enabled = false, device_update_interval = never — this is where battery notices come from",
            telemetry.map { !$0.deviceTelemetryEnabled && $0.deviceUpdateInterval >= never })
        add("envtel", "Environment, power and air-quality telemetry off",
            "environment_measurement_enabled, power_measurement_enabled, air_quality_enabled = false",
            telemetry.map { !$0.environmentMeasurementEnabled && !$0.powerMeasurementEnabled && !$0.airQualityEnabled })
        add("gps", "GPS disabled",
            "gps_mode = DISABLED — the receiver is powered down",
            position.map { $0.gpsMode == .disabled })
        add("pos", "Position broadcasts off",
            "fixed_position = false, position_broadcast_secs = never, smart broadcast off",
            position.map { !$0.fixedPosition && $0.positionBroadcastSecs >= never && !$0.positionBroadcastSmartEnabled })
        add("nodeinfo", "Node info every 4 hours",
            "node_info_broadcast_secs = 14400",
            device.map { $0.nodeInfoBroadcastSecs == nodeInfoSecs })
        add("screen", "Screen off after 30 s",
            "display.screen_on_secs = 30",
            display.map { $0.screenOnSecs > 0 && $0.screenOnSecs <= 30 })
        add("led", "LED heartbeat off",
            "device.led_heartbeat_disabled = true",
            device.map { $0.ledHeartbeatDisabled })
        add("wifi", "Wi-Fi off",
            "network.wifi_enabled = false",
            network.map { !$0.wifiEnabled })
        add("modules", "Self-transmitting modules off",
            "neighbor_info, range_test, store_forward, detection_sensor, paxcounter, mqtt all disabled",
            modules.allKnown
                ? !(modules.neighborInfo!.enabled || modules.rangeTest!.enabled || modules.storeForward!.enabled
                    || modules.detectionSensor!.enabled || modules.paxcounter!.enabled || modules.mqtt!.enabled)
                : nil)
        return out
    }

    static func isSatisfied(telemetry: ModuleConfig.TelemetryConfig?, position: Config.PositionConfig?,
                            device: Config.DeviceConfig?, modules: RadioManager.ModuleConfigs,
                            power: Config.PowerConfig?, display: Config.DisplayConfig?,
                            network: Config.NetworkConfig?) -> Bool {
        checks(telemetry: telemetry, position: position, device: device, modules: modules,
               power: power, display: display, network: network).allSatisfy(\.satisfied)
    }

    /// The profile applied on top of the radio's current values.
    static func apply(telemetry: inout ModuleConfig.TelemetryConfig, position: inout Config.PositionConfig,
                      device: inout Config.DeviceConfig, modules: inout RadioManager.ModuleConfigs,
                      power: inout Config.PowerConfig, display: inout Config.DisplayConfig,
                      network: inout Config.NetworkConfig) {
        // power.is_power_saving is deliberately NOT here: it disables
        // Bluetooth, so the radio vanishes from Hops (it took a SenseCAP
        // offline). It has its own switch with a warning.
        _ = power
        display.screenOnSecs = 30
        device.ledHeartbeatDisabled = true
        network.wifiEnabled = false
        telemetry.deviceTelemetryEnabled = false
        telemetry.deviceUpdateInterval = never
        telemetry.environmentMeasurementEnabled = false
        telemetry.powerMeasurementEnabled = false
        telemetry.airQualityEnabled = false
        position.gpsMode = .disabled
        position.fixedPosition = false
        position.positionBroadcastSecs = never
        position.positionBroadcastSmartEnabled = false
        device.nodeInfoBroadcastSecs = nodeInfoSecs
        modules.neighborInfo?.enabled = false
        modules.rangeTest?.enabled = false
        modules.storeForward?.enabled = false
        modules.detectionSensor?.enabled = false
        modules.paxcounter?.enabled = false
        modules.mqtt?.enabled = false
    }

    /// Firmware defaults for what the profile touched — "normal power".
    static func restoreDefaults(telemetry: inout ModuleConfig.TelemetryConfig, position: inout Config.PositionConfig,
                                device: inout Config.DeviceConfig, power: inout Config.PowerConfig,
                                display: inout Config.DisplayConfig) {
        _ = power
        display.screenOnSecs = 60
        device.ledHeartbeatDisabled = false
        telemetry.deviceTelemetryEnabled = true
        telemetry.deviceUpdateInterval = 1800
        position.gpsMode = .enabled
        position.positionBroadcastSecs = 900
        position.positionBroadcastSmartEnabled = true
        device.nodeInfoBroadcastSecs = 10800
    }
}
