import SwiftUI
import MeshtasticProtobufs

// Device-config editors: Bluetooth, Display, Position. Each loads the value
// received in the connect-time config dump and writes back one Config section.

// MARK: - Bluetooth

struct BluetoothSettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = true
    @State private var modeRaw = 0
    @State private var fixedPin = ""

    var body: some View {
        Form {
            if radio.bluetoothConfig == nil {
                notLoadedNote
            }
            Section {
                Toggle("Bluetooth Enabled", isOn: $enabled)
                Picker("Pairing", selection: $modeRaw) {
                    Text("Random PIN").tag(0)
                    Text("Fixed PIN").tag(1)
                    Text("No PIN").tag(2)
                }
                if modeRaw == 1 {
                    TextField("6-digit PIN", text: $fixedPin)
                        .keyboardType(.numberPad)
                        .onChange(of: fixedPin) { _, newValue in
                            fixedPin = String(newValue.filter(\.isNumber).prefix(6))
                        }
                }
            } footer: {
                Text("Careful: disabling Bluetooth or changing pairing disconnects Hops — you'd need the radio's buttons or another transport to undo it.")
            }
            saveButton {
                var bluetooth = radio.bluetoothConfig ?? Config.BluetoothConfig()
                bluetooth.enabled = enabled
                bluetooth.mode = Config.BluetoothConfig.PairingMode(rawValue: modeRaw) ?? .randomPin
                if modeRaw == 1, let pin = UInt32(fixedPin), pin >= 100_000 {
                    bluetooth.fixedPin = pin
                }
                var config = Config()
                config.bluetooth = bluetooth
                radio.applyConfig(config)
                dismiss()
            }
        }
        .navigationTitle("Bluetooth")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let bluetooth = radio.bluetoothConfig else { return }
            enabled = bluetooth.enabled
            modeRaw = bluetooth.mode.rawValue
            if bluetooth.fixedPin > 0 { fixedPin = String(bluetooth.fixedPin) }
        }
    }
}

// MARK: - Display

struct DisplaySettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var screenOnSecs = 60
    @State private var unitsRaw = 0
    @State private var flipScreen = false
    @State private var compassNorthTop = false
    @State private var wakeOnTapOrMotion = false
    @State private var use12HClock = false

    private static let screenChoices: [(String, Int)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60),
        ("5 minutes", 300), ("10 minutes", 600), ("Always on", 0),
    ]

    var body: some View {
        Form {
            if radio.displayConfig == nil {
                notLoadedNote
            }
            Section {
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
            saveButton {
                var display = radio.displayConfig ?? Config.DisplayConfig()
                display.screenOnSecs = UInt32(screenOnSecs)
                display.units = Config.DisplayConfig.DisplayUnits(rawValue: unitsRaw) ?? .metric
                display.use12HClock = use12HClock
                display.flipScreen = flipScreen
                display.compassNorthTop = compassNorthTop
                display.wakeOnTapOrMotion = wakeOnTapOrMotion
                var config = Config()
                config.display = display
                radio.applyConfig(config)
                dismiss()
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let display = radio.displayConfig else { return }
            screenOnSecs = Self.screenChoices.map(\.1).contains(Int(display.screenOnSecs))
                ? Int(display.screenOnSecs) : 60
            unitsRaw = display.units.rawValue
            use12HClock = display.use12HClock
            flipScreen = display.flipScreen
            compassNorthTop = display.compassNorthTop
            wakeOnTapOrMotion = display.wakeOnTapOrMotion
        }
    }
}

// MARK: - Position

struct PositionSettingsView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    @State private var gpsModeRaw = 0
    @State private var broadcastSecs = 900
    @State private var smartEnabled = true
    @State private var smartMinDistance = 100
    @State private var smartMinSecs = 30
    @State private var fixedPosition = false

    private static let intervalChoices: [(String, Int)] = [
        ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
        ("1 hour", 3600), ("6 hours", 21600),
    ]

    var body: some View {
        Form {
            if radio.positionConfig == nil {
                notLoadedNote
            }
            Section {
                Picker("GPS", selection: $gpsModeRaw) {
                    Text("Enabled").tag(1)
                    Text("Disabled").tag(0)
                    Text("Not present").tag(2)
                }
                Toggle("Fixed position", isOn: $fixedPosition)
            } footer: {
                Text("Fixed position keeps broadcasting the radio's current location without a GPS — right for a home or roof node.")
            }
            Section {
                Picker("Broadcast interval", selection: $broadcastSecs) {
                    ForEach(Self.intervalChoices, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                Toggle("Smart broadcast", isOn: $smartEnabled)
                if smartEnabled {
                    Stepper("Min distance: \(smartMinDistance) m", value: $smartMinDistance, in: 30...500, step: 10)
                    Stepper("Min interval: \(smartMinSecs) s", value: $smartMinSecs, in: 30...600, step: 30)
                }
            } footer: {
                Text("Smart broadcast sends positions when you've actually moved, saving airtime — communities recommend it for mobile nodes.")
            }
            saveButton {
                var position = radio.positionConfig ?? Config.PositionConfig()
                position.gpsMode = Config.PositionConfig.GpsMode(rawValue: gpsModeRaw) ?? .enabled
                position.positionBroadcastSecs = UInt32(broadcastSecs)
                position.positionBroadcastSmartEnabled = smartEnabled
                position.broadcastSmartMinimumDistance = UInt32(smartMinDistance)
                position.broadcastSmartMinimumIntervalSecs = UInt32(smartMinSecs)
                position.fixedPosition = fixedPosition
                var config = Config()
                config.position = position
                radio.applyConfig(config)
                dismiss()
            }
        }
        .navigationTitle("Position")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let position = radio.positionConfig else { return }
            gpsModeRaw = position.gpsMode.rawValue
            broadcastSecs = Self.intervalChoices.map(\.1).contains(Int(position.positionBroadcastSecs))
                ? Int(position.positionBroadcastSecs) : 900
            smartEnabled = position.positionBroadcastSmartEnabled
            if position.broadcastSmartMinimumDistance > 0 {
                smartMinDistance = Int(position.broadcastSmartMinimumDistance)
            }
            if position.broadcastSmartMinimumIntervalSecs > 0 {
                smartMinSecs = Int(position.broadcastSmartMinimumIntervalSecs)
            }
            fixedPosition = position.fixedPosition
        }
    }
}

// MARK: - Shared bits

private var notLoadedNote: some View {
    Section {
        Label {
            Text("Current values load from the radio on connect; saving now writes over whatever is on the device.")
                .font(.footnote)
        } icon: {
            Image(systemName: "info.circle")
        }
    }
}

private func saveButton(_ action: @escaping () -> Void) -> some View {
    Section {
        Button(action: action) {
            Text("Save to Radio")
                .frame(maxWidth: .infinity)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    } footer: {
        Text("The radio may restart briefly to apply; Hops reconnects automatically.")
    }
}
