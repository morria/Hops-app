import SwiftUI
import MeshtasticProtobufs

/// One screen for the radio's device behavior: Bluetooth, Display, Position,
/// and Telemetry. Values load from the connect-time dump (plus live read-backs);
/// a single Save writes each section via admin.
struct DeviceConfigurationView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    // Bluetooth
    @State private var btEnabled = true
    @State private var btModeRaw = 0
    @State private var btFixedPin = ""
    // Display
    @State private var screenOnSecs = 60
    @State private var unitsRaw = 0
    @State private var use12HClock = false
    @State private var flipScreen = false
    @State private var compassNorthTop = false
    @State private var wakeOnTapOrMotion = false
    // Position
    @State private var gpsModeRaw = 1
    @State private var broadcastSecs = 900
    @State private var smartEnabled = true
    @State private var smartMinDistance = 100
    @State private var smartMinSecs = 30
    @State private var fixedPosition = false
    // Telemetry
    @State private var deviceInterval = 1800
    // Device (rebroadcast)
    @State private var rebroadcastRaw = 0

    private static let rebroadcastChoices: [(String, Int)] = [
        ("All packets", 0),
        ("All — skip decoding", 1),
        ("Local only", 2),
        ("Known nodes only", 3),
        ("Never relay", 4),
        ("Core ports only", 5),
    ]

    private static let screenChoices: [(String, Int)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
        ("5 minutes", 300), ("10 minutes", 600), ("Always on", 0),
    ]
    private static let positionChoices: [(String, Int)] = [
        ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
        ("1 hour", 3600), ("6 hours", 21600),
    ]
    /// Firmware has no boolean for device metrics; "off" is an interval the
    /// radio will never reach.
    static let telemetryOff = 4_294_967_295
    private static let telemetryChoices: [(String, Int)] = [
        ("30 minutes (firmware default)", 1800), ("1 hour", 3600), ("2 hours", 7200),
        ("6 hours (community recommended)", 21600), ("12 hours", 43200), ("24 hours", 86400),
        ("Off — never broadcast", telemetryOff),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Bluetooth Enabled", isOn: $btEnabled)
                Picker("Pairing", selection: $btModeRaw) {
                    Text("Random PIN").tag(0)
                    Text("Fixed PIN").tag(1)
                    Text("No PIN").tag(2)
                }
                if btModeRaw == 1 {
                    TextField("6-digit PIN", text: $btFixedPin)
                        .keyboardType(.numberPad)
                        .onChange(of: btFixedPin) { _, newValue in
                            btFixedPin = String(newValue.filter(\.isNumber).prefix(6))
                        }
                }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Careful: disabling Bluetooth or changing pairing disconnects Hops — undoing it needs the radio's buttons or another transport.")
            }

            Section("Display") {
                Picker("Screen timeout", selection: $screenOnSecs) {
                    ForEach(Self.screenChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Picker("Units", selection: $unitsRaw) {
                    Text("Metric").tag(0)
                    Text("Imperial").tag(1)
                }
                Toggle("12-hour clock", isOn: $use12HClock)
                Toggle("Flip screen", isOn: $flipScreen)
                Toggle("Compass north up", isOn: $compassNorthTop)
                Toggle("Wake on tap or motion", isOn: $wakeOnTapOrMotion)
            }

            Section {
                Picker("GPS", selection: $gpsModeRaw) {
                    Text("Enabled").tag(1)
                    Text("Disabled").tag(0)
                    Text("Not present").tag(2)
                }
                Toggle("Fixed position", isOn: $fixedPosition)
                Picker("Broadcast interval", selection: $broadcastSecs) {
                    ForEach(Self.positionChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Toggle("Smart broadcast", isOn: $smartEnabled)
                if smartEnabled {
                    Stepper("Min distance: \(smartMinDistance) m", value: $smartMinDistance, in: 30...500, step: 10)
                    Stepper("Min interval: \(smartMinSecs) s", value: $smartMinSecs, in: 30...600, step: 30)
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Smart broadcast sends positions when you've actually moved, saving airtime. Fixed position suits a home or roof node without GPS.")
            }

            Section {
                Picker("Battery & device metrics", selection: $deviceInterval) {
                    ForEach(Self.telemetryChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
            } header: {
                Text("Telemetry")
            } footer: {
                Text("Every broadcast spends the whole mesh's airtime — 6 hours is plenty; bayme.sh and nyme.sh both recommend it.")
            }

            Section {
                Picker("Relay for others", selection: $rebroadcastRaw) {
                    ForEach(Self.rebroadcastChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .disabled(radio.deviceConfig == nil)
            } header: {
                Text("Mesh Relay")
            } footer: {
                Text(radio.deviceConfig == nil
                     ? "Reading current setting from the radio…"
                     : "Careful: “Core ports only” makes the radio silently drop app traffic like Meshsites — it never even reaches Hops. For a phone-carried radio, “Never relay” saves the same airtime without going deaf.")
            }

            Section {
                Button {
                    save()
                    dismiss()
                } label: {
                    Text("Save to Radio")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Saves all four sections. The radio may restart briefly; Hops reconnects automatically.")
            }
        }
        .navigationTitle("Device Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            radio.requestModuleConfig(.telemetryConfig)
            radio.requestConfig(.deviceConfig)
            syncAll()
        }
        .onChange(of: radio.deviceConfig) { syncDevice() }
        .onChange(of: radio.bluetoothConfig) { syncBluetooth() }
        .onChange(of: radio.displayConfig) { syncDisplay() }
        .onChange(of: radio.positionConfig) { syncPosition() }
        .onChange(of: radio.telemetryConfig) { syncTelemetry() }
    }

    // MARK: - Load

    private func syncAll() {
        syncBluetooth(); syncDisplay(); syncPosition(); syncTelemetry(); syncDevice()
    }

    private func syncDevice() {
        guard let device = radio.deviceConfig else { return }
        rebroadcastRaw = device.rebroadcastMode.rawValue
    }

    private func syncBluetooth() {
        guard let bluetooth = radio.bluetoothConfig else { return }
        btEnabled = bluetooth.enabled
        btModeRaw = bluetooth.mode.rawValue
        if bluetooth.fixedPin > 0 { btFixedPin = String(bluetooth.fixedPin) }
    }

    private func syncDisplay() {
        guard let display = radio.displayConfig else { return }
        screenOnSecs = Self.screenChoices.map(\.1).contains(Int(display.screenOnSecs)) ? Int(display.screenOnSecs) : 60
        unitsRaw = display.units.rawValue
        use12HClock = display.use12HClock
        flipScreen = display.flipScreen
        compassNorthTop = display.compassNorthTop
        wakeOnTapOrMotion = display.wakeOnTapOrMotion
    }

    private func syncPosition() {
        guard let position = radio.positionConfig else { return }
        gpsModeRaw = position.gpsMode.rawValue
        broadcastSecs = Self.positionChoices.map(\.1).contains(Int(position.positionBroadcastSecs)) ? Int(position.positionBroadcastSecs) : 900
        smartEnabled = position.positionBroadcastSmartEnabled
        if position.broadcastSmartMinimumDistance > 0 { smartMinDistance = Int(position.broadcastSmartMinimumDistance) }
        if position.broadcastSmartMinimumIntervalSecs > 0 { smartMinSecs = Int(position.broadcastSmartMinimumIntervalSecs) }
        fixedPosition = position.fixedPosition
    }

    private func syncTelemetry() {
        guard let telemetry = radio.telemetryConfig else { return }
        var current = telemetry.deviceUpdateInterval == 0 ? 1800 : Int(telemetry.deviceUpdateInterval)
        // Anything a year or beyond reads back as Off.
        if current >= 31_536_000 { current = Self.telemetryOff }
        if Self.telemetryChoices.map(\.1).contains(current) { deviceInterval = current }
    }

    // MARK: - Save

    private func save() {
        var bluetooth = radio.bluetoothConfig ?? Config.BluetoothConfig()
        bluetooth.enabled = btEnabled
        bluetooth.mode = Config.BluetoothConfig.PairingMode(rawValue: btModeRaw) ?? .randomPin
        if btModeRaw == 1, let pin = UInt32(btFixedPin), pin >= 100_000 { bluetooth.fixedPin = pin }
        var btConfig = Config(); btConfig.bluetooth = bluetooth
        radio.applyConfig(btConfig)

        var display = radio.displayConfig ?? Config.DisplayConfig()
        display.screenOnSecs = UInt32(screenOnSecs)
        display.units = Config.DisplayConfig.DisplayUnits(rawValue: unitsRaw) ?? .metric
        display.use12HClock = use12HClock
        display.flipScreen = flipScreen
        display.compassNorthTop = compassNorthTop
        display.wakeOnTapOrMotion = wakeOnTapOrMotion
        var displayConfig = Config(); displayConfig.display = display
        radio.applyConfig(displayConfig)

        var position = radio.positionConfig ?? Config.PositionConfig()
        position.gpsMode = Config.PositionConfig.GpsMode(rawValue: gpsModeRaw) ?? .enabled
        position.positionBroadcastSecs = UInt32(broadcastSecs)
        position.positionBroadcastSmartEnabled = smartEnabled
        position.broadcastSmartMinimumDistance = UInt32(smartMinDistance)
        position.broadcastSmartMinimumIntervalSecs = UInt32(smartMinSecs)
        position.fixedPosition = fixedPosition
        var positionConfig = Config(); positionConfig.position = position
        radio.applyConfig(positionConfig)

        var telemetry = radio.telemetryConfig ?? ModuleConfig.TelemetryConfig()
        telemetry.deviceUpdateInterval = UInt32(deviceInterval)
        var moduleConfig = ModuleConfig(); moduleConfig.telemetry = telemetry
        radio.applyModuleConfig(moduleConfig)

        // Device config only ever writes on top of the radio's own values —
        // a blank baseline would wipe the role and other fields.
        if var device = radio.deviceConfig {
            device.rebroadcastMode = Config.DeviceConfig.RebroadcastMode(rawValue: rebroadcastRaw) ?? .all
            var deviceWrite = Config(); deviceWrite.device = device
            radio.applyConfig(deviceWrite)
        }
    }
}
