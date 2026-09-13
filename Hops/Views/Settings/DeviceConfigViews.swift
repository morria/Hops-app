import SwiftUI
import MeshtasticProtobufs

/// One screen for the radio's device behavior: power, Bluetooth, display,
/// position, telemetry, node info, relay, and the modules that transmit on
/// their own. Values load from the connect-time dump (plus live read-backs);
/// a single Save writes each section via admin.
struct DeviceConfigurationView: View {
    /// Which fleet radio; nil = the transmit radio (main Settings entry).
    var nodeNum: Int64? = nil
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.dismiss) private var dismiss

    /// The configuration of the radio this screen edits (TODO 196).
    private var cfg: RadioManager.LinkConfigs {
        if let nodeNum, let c = radio.configsByNode[nodeNum] { return c }
        if nodeNum == nil, let c = radio.configsByNode[radio.myNodeNum] { return c }
        return RadioManager.LinkConfigs(bluetooth: cfg.bluetooth, device: cfg.device,
                                        display: cfg.display, position: cfg.position,
                                        power: cfg.power, network: cfg.network,
                                        lora: cfg.lora, telemetry: cfg.telemetry,
                                        modules: cfg.modules)
    }
    private var target: Int64? { nodeNum }
    private var radioName: String {
        let num = nodeNum ?? radio.myNodeNum
        return radio.fleet.first { $0.nodeNum == num }?.displayName ?? String(format: "!%08x", UInt32(truncatingIfNeeded: num))
    }

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
    @State private var deviceTelemetryEnabled = true
    @State private var deviceInterval = 1800
    @State private var envEnabled = false
    @State private var powerEnabled = false
    @State private var airEnabled = false
    // Device
    @State private var nodeInfoSecs = 10800
    @State private var rebroadcastRaw = 0
    // Modules that transmit on their own (nil = radio hasn't reported yet)
    @State private var neighborInfoOn: Bool?
    @State private var rangeTestOn: Bool?
    @State private var storeForwardOn: Bool?
    @State private var detectionSensorOn: Bool?
    @State private var paxcounterOn: Bool?
    @State private var mqttOn: Bool?
    @State private var lowPowerNote: String?
    @State private var confirmSleepSave = false
    // Power / network / LoRa
    @State private var powerSaving = false
    @State private var ledHeartbeatDisabled = false
    @State private var wifiEnabled = false
    @State private var txEnabled = true

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
    static let never = Int(LowPowerProfile.never)
    private static let positionChoices: [(String, Int)] = [
        ("5 minutes", 300), ("15 minutes", 900), ("30 minutes", 1800),
        ("1 hour", 3600), ("6 hours", 21600), ("Never", never),
    ]
    /// Firmware has no boolean for the interval; "off" is one the radio
    /// will never reach.
    static let telemetryOff = never
    private static let telemetryChoices: [(String, Int)] = [
        ("30 minutes (firmware default)", 1800), ("1 hour", 3600), ("2 hours", 7200),
        ("6 hours (community recommended)", 21600), ("12 hours", 43200), ("24 hours", 86400),
        ("Never", telemetryOff),
    ]
    private static let nodeInfoChoices: [(String, Int)] = [
        ("1 hour (firmware minimum)", 3600), ("3 hours (firmware default)", 10800),
        ("4 hours (very low power)", 14400), ("12 hours", 43200), ("24 hours", 86400),
    ]

    // MARK: - Very low power (derived from the form, so any edit turns it off)

    private var formTelemetry: ModuleConfig.TelemetryConfig {
        var t = cfg.telemetry ?? ModuleConfig.TelemetryConfig()
        t.deviceTelemetryEnabled = deviceTelemetryEnabled
        t.deviceUpdateInterval = UInt32(deviceInterval)
        t.environmentMeasurementEnabled = envEnabled
        t.powerMeasurementEnabled = powerEnabled
        t.airQualityEnabled = airEnabled
        return t
    }
    private var formPosition: Config.PositionConfig {
        var p = cfg.position ?? Config.PositionConfig()
        p.gpsMode = Config.PositionConfig.GpsMode(rawValue: gpsModeRaw) ?? .enabled
        p.positionBroadcastSecs = UInt32(broadcastSecs)
        p.positionBroadcastSmartEnabled = smartEnabled
        p.broadcastSmartMinimumDistance = UInt32(smartMinDistance)
        p.broadcastSmartMinimumIntervalSecs = UInt32(smartMinSecs)
        p.fixedPosition = fixedPosition
        return p
    }
    private var formDevice: Config.DeviceConfig? {
        guard var d = cfg.device else { return nil }
        d.nodeInfoBroadcastSecs = UInt32(nodeInfoSecs)
        d.rebroadcastMode = Config.DeviceConfig.RebroadcastMode(rawValue: rebroadcastRaw) ?? .all
        d.ledHeartbeatDisabled = ledHeartbeatDisabled
        return d
    }
    private var formPower: Config.PowerConfig? {
        guard var p = cfg.power else { return nil }
        p.isPowerSaving = powerSaving
        return p
    }
    private var formDisplay: Config.DisplayConfig {
        var d = cfg.display ?? Config.DisplayConfig()
        d.screenOnSecs = UInt32(screenOnSecs)
        d.units = Config.DisplayConfig.DisplayUnits(rawValue: unitsRaw) ?? .metric
        d.use12HClock = use12HClock
        d.flipScreen = flipScreen
        d.compassNorthTop = compassNorthTop
        d.wakeOnTapOrMotion = wakeOnTapOrMotion
        return d
    }
    private var formNetwork: Config.NetworkConfig? {
        guard var n = cfg.network else { return nil }
        n.wifiEnabled = wifiEnabled
        return n
    }
    private var formModules: RadioManager.ModuleConfigs {
        var m = cfg.modules
        if let on = neighborInfoOn { m.neighborInfo?.enabled = on }
        if let on = rangeTestOn { m.rangeTest?.enabled = on }
        if let on = storeForwardOn { m.storeForward?.enabled = on }
        if let on = detectionSensorOn { m.detectionSensor?.enabled = on }
        if let on = paxcounterOn { m.paxcounter?.enabled = on }
        if let on = mqttOn { m.mqtt?.enabled = on }
        return m
    }
    private var checks: [LowPowerProfile.Check] {
        LowPowerProfile.checks(telemetry: formTelemetry, position: formPosition, device: formDevice, modules: formModules,
                               power: formPower, display: formDisplay, network: formNetwork)
    }


    /// One checklist item flipped by hand: on = its recommended state, off =
    /// the firmware default where one exists (some items have no "on" to go
    /// back to, and simply stay).
    private func setCheck(_ id: String, _ on: Bool) {
        lowPowerNote = "Tap Save to Radio to apply."
        switch id {
        case "devtel":
            deviceTelemetryEnabled = !on
            deviceInterval = on ? Self.never : 1800
        case "envtel":
            if on { envEnabled = false; powerEnabled = false; airEnabled = false }
        case "gps":
            gpsModeRaw = on ? Config.PositionConfig.GpsMode.disabled.rawValue : Config.PositionConfig.GpsMode.enabled.rawValue
        case "pos":
            if on { fixedPosition = false; broadcastSecs = Self.never; smartEnabled = false }
            else { broadcastSecs = 900; smartEnabled = true }
        case "nodeinfo":
            nodeInfoSecs = on ? Int(LowPowerProfile.nodeInfoSecs) : 10800
        case "screen":
            screenOnSecs = on ? 30 : 60
        case "led":
            ledHeartbeatDisabled = on
        case "wifi":
            wifiEnabled = !on
        case "modules":
            if on {
                if neighborInfoOn != nil { neighborInfoOn = false }
                if rangeTestOn != nil { rangeTestOn = false }
                if storeForwardOn != nil { storeForwardOn = false }
                if detectionSensorOn != nil { detectionSensorOn = false }
                if paxcounterOn != nil { paxcounterOn = false }
                if mqttOn != nil { mqttOn = false }
            }
        default:
            break
        }
    }


    @State private var nickname = ""
    @State private var location = "other"
    @State private var confirmForget = false
    @State private var confirmRevoke = false
    @State private var confirmRegenerate = false
    @State private var showSetKey = false
    @State private var newPrivateKey = ""
    @State private var confirmTxOffSave = false
    @State private var savedNote: String?

    /// Anything on the form that differs from what the radio reported.
    private var hasChanges: Bool {
        guard cfg.device != nil else { return false }
        if formTelemetry != (cfg.telemetry ?? ModuleConfig.TelemetryConfig()) { return true }
        if formPosition != (cfg.position ?? Config.PositionConfig()) { return true }
        if let d = formDevice, d != cfg.device { return true }
        if formDisplay != (cfg.display ?? Config.DisplayConfig()) { return true }
        if let pw = formPower, pw != cfg.power { return true }
        if let nw = formNetwork, nw != cfg.network { return true }
        if let lora = cfg.lora, lora.txEnabled != txEnabled { return true }
        if formModules != cfg.modules { return true }
        var bt = cfg.bluetooth ?? Config.BluetoothConfig()
        bt.enabled = btEnabled
        bt.mode = Config.BluetoothConfig.PairingMode(rawValue: btModeRaw) ?? .randomPin
        if bt != (cfg.bluetooth ?? Config.BluetoothConfig()) { return true }
        return false
    }
    private var stillLoading: Bool {
        cfg.device == nil || cfg.position == nil || cfg.telemetry == nil || cfg.lora == nil
    }

    private var fleetEntry: MessageStore.RadioSnapshot? {
        let num = nodeNum ?? radio.myNodeNum
        return radio.fleet.first { $0.nodeNum == num }
    }
    private var attachedEntry: RadioManager.AttachedRadio? {
        let num = nodeNum ?? radio.myNodeNum
        return radio.attached.first { $0.nodeNum == num }
    }

    var body: some View {
        Form {
            if let num = nodeNum ?? (radio.fleet.isEmpty ? nil : radio.myNodeNum),
               radio.fleet.contains(where: { $0.nodeNum == num }) {
                Section {
                    TextField("Nickname (e.g. Home upstairs)", text: $nickname)
                        .onSubmit { radio.renameRadio(num, nickname: nickname) }
                    Picker("Location", selection: $location) {
                        Text("Home").tag("home")
                        Text("Office").tag("office")
                        Text("Mobile").tag("mobile")
                        Text("Other").tag("other")
                    }
                    .onChange(of: location) { _, tag in radio.setRadioLocation(num, tag: tag) }
                    LabeledContent("Node ID", value: String(format: "!%08x", UInt32(truncatingIfNeeded: num)))
                    if let fw = fleetEntry?.firmware, !fw.isEmpty { LabeledContent("Firmware", value: "v\(fw)") }
                    if let security = cfg.security, security.publicKey.count == 32 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Encryption key")
                            KeyFingerprintView(key: security.publicKey)
                            Text(security.publicKey.base64EncodedString())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    NavigationLink {
                        MeshSetupView(isFirstRun: false, nodeNum: num)
                    } label: {
                        LabeledContent("Mesh setup") {
                            let lora = cfg.lora
                            Text(lora.map { "\(String(describing: $0.region).uppercased()) · slot \($0.channelNum)" } ?? "—")
                        }
                    }
                } header: {
                    if stillLoading {
                        Label("Reading from \(radioName)…", systemImage: "arrow.triangle.2.circlepath")
                            .textCase(nil)
                    } else {
                        Text("This radio")
                    }
                } footer: {
                    Label("Holds only its last 8–32 packets for you while you're not attached.", systemImage: "exclamationmark.triangle")
                }

                RadioSuggestionsSection(nodeNum: num)
            }

            Section {
                LabeledContent("Battery") {
                    if let battery = fleetEntry?.lastBattery, battery >= 0 {
                        HStack(spacing: 6) {
                            Image(systemName: battery > 100 ? "powerplug" : battery > 60 ? "battery.100" : battery > 25 ? "battery.50" : "battery.25")
                            Text(battery > 100 ? "Plugged in" : "\(battery)%")
                        }
                        .foregroundStyle(battery <= 25 ? Color.red : Color.secondary)
                        .fixedSize()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                ForEach(checks) { check in
                    Toggle(check.label, isOn: Binding(get: { check.satisfied },
                                                      set: { setCheck(check.id, $0) }))
                }
                if let lowPowerNote {
                    Text(lowPowerNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Power")
            } footer: {
                Text("Each switch turns off something the radio does on its own. On means the low-power setting is in place; changes apply when you tap Save. Bluetooth stays on so Hops can still reach the radio.")
            }

            Section {
                Toggle("Sleep between packets", isOn: $powerSaving)
                    .disabled(cfg.power == nil)
            } header: {
                Text("Sleep")
            } footer: {
                Text("Turns Bluetooth off. Hops can't reach the radio again until you press its button or power-cycle it. Only for radios you never connect a phone to.")
            }

            Section {
                Toggle("Transmit", isOn: $txEnabled)
                    .disabled(cfg.lora == nil)
            } header: {
                Text("Radio")
            } footer: {
                Text(txEnabled
                     ? "lora.tx_enabled. Off makes the radio listen only: no acks, no node info, and nothing you send from this radio leaves it."
                     : "Transmit is OFF — this radio only listens. Nothing sent through it reaches the mesh, and other radios can't confirm anything to it.")
            }

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
                    ForEach(Self.screenChoices, id: \.1) { label, value in Text(label).tag(value) }
                }
                Picker("Screen units", selection: $unitsRaw) {
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
                    ForEach(Self.positionChoices, id: \.1) { label, value in Text(label).tag(value) }
                }
                Toggle("Smart broadcast", isOn: $smartEnabled)
                if smartEnabled {
                    Stepper("Min distance: \(smartMinDistance) m", value: $smartMinDistance, in: 30...500, step: 10)
                    Stepper("Min interval: \(smartMinSecs) s", value: $smartMinSecs, in: 30...600, step: 30)
                }
            } header: {
                Text("Position")
            } footer: {
                Text("To shut GPS off completely: GPS Disabled, Fixed position off, Broadcast interval Never, Smart broadcast off. Disabled powers the receiver down; Not present tells the firmware there is no GPS hardware at all.")
            }

            Section {
                Toggle("Device telemetry (battery, voltage, uptime)", isOn: $deviceTelemetryEnabled)
                Picker("Broadcast interval", selection: $deviceInterval) {
                    ForEach(Self.telemetryChoices, id: \.1) { label, value in Text(label).tag(value) }
                }
                Toggle("Environment sensors", isOn: $envEnabled)
                Toggle("Power measurement", isOn: $powerEnabled)
                Toggle("Air quality", isOn: $airEnabled)
            } header: {
                Text("Telemetry")
            } footer: {
                Text("Battery updates come from device telemetry. To stop them entirely turn Device telemetry off and set the interval to Never. Every broadcast spends the whole mesh's airtime — 6 hours is plenty when it's on.")
            }

            Section {
                Picker("Node info broadcast", selection: $nodeInfoSecs) {
                    ForEach(Self.nodeInfoChoices, id: \.1) { label, value in Text(label).tag(value) }
                }
                .disabled(cfg.device == nil)
                Picker("Relay for others", selection: $rebroadcastRaw) {
                    ForEach(Self.rebroadcastChoices, id: \.1) { label, value in Text(label).tag(value) }
                }
                .disabled(cfg.device == nil)
            } header: {
                Text("Mesh")
            } footer: {
                Text("Node info is how others learn your name and key; the firmware won't go below 1 hour. “All packets” is the standard relay choice. Careful: “Core ports only” silently drops app traffic like Meshsites, and some firmware fails to apply “Never relay”.")
            }

            Section {
                moduleToggle("Neighbor info", $neighborInfoOn)
                moduleToggle("Range test", $rangeTestOn)
                moduleToggle("Store & forward", $storeForwardOn)
                moduleToggle("Detection sensor", $detectionSensorOn)
                moduleToggle("Paxcounter", $paxcounterOn)
                moduleToggle("MQTT", $mqttOn)
            } header: {
                Text("Modules that transmit on their own")
            } footer: {
                Text("Each of these sends packets without you. A dimmed row means the radio hasn't reported that module yet.")
            }


            Section {
                let num = nodeNum ?? radio.myNodeNum
                Button("Reboot Radio") {
                    radio.rebootRadio(via: nodeNum)
                    dismiss()
                }
                if radio.userDisconnectedRadios.contains(num) {
                    Button("Connect") { radio.reconnectByUser(radio: num) }
                } else {
                    Button("Disconnect", role: .destructive) {
                        radio.disconnectByUser(radio: num)
                        dismiss()
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Reboot restarts the radio with Bluetooth on; it's back in about 20 seconds. Disconnect keeps the radio in your fleet but stops Hops from attaching until you connect again.")
            }

            if fleetEntry != nil {
                Section {
                    if cfg.security?.publicKey.count == 32 {
                        Button("Regenerate Keys…") { confirmRegenerate = true }
                            .confirmationDialog("Regenerate this radio's keys?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                                Button("Regenerate", role: .destructive) { radio.setPrivateKey(Data(), via: nodeNum) }
                            } message: {
                                Text("The radio makes a new keypair and restarts. Everyone who has messaged this radio will see a key change and need to reset it before their direct messages get through again.")
                            }
                        Button("Set Private Key…") { showSetKey = true }
                            .alert("Private key", isPresented: $showSetKey) {
                                TextField("Base64, 32 bytes", text: $newPrivateKey)
                                Button("Set", role: .destructive) {
                                    if let data = Data(base64Encoded: newPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 {
                                        radio.setPrivateKey(data, via: nodeNum)
                                    }
                                    newPrivateKey = ""
                                }
                                Button("Cancel", role: .cancel) { newPrivateKey = "" }
                            } message: {
                                Text("Use this to give a replacement radio the same identity. The public key is derived by the radio; it restarts.")
                            }
                    }
                    Button("Forget This Radio…", role: .destructive) { confirmForget = true }
                        .confirmationDialog("Forget this radio?", isPresented: $confirmForget, titleVisibility: .visible) {
                            Button("Forget Radio", role: .destructive) {
                                radio.forget(radio: nodeNum ?? radio.myNodeNum)
                                dismiss()
                            }
                        } message: {
                            Text("Removes it from your fleet on every device. Messages stay. You can pair it again anytime.")
                        }
                    Button("Forget & Revoke Keys…", role: .destructive) { confirmRevoke = true }
                        .confirmationDialog("Lost or stolen?", isPresented: $confirmRevoke, titleVisibility: .visible) {
                            Button("Forget and Rotate Channel Keys", role: .destructive) {
                                radio.forgetAndRevoke(radio: nodeNum ?? radio.myNodeNum)
                                dismiss()
                            }
                        } message: {
                            Text("Forgets the radio and gives every channel with a custom key a new one, applied to your sending radio now. Your other radios will show as differing until you apply fleet settings. Anyone else on a rotated channel needs the new QR.")
                        }
                } header: {
                    Text("Irreversible")
                } footer: {
                    Text("Each of these changes what other people see from this radio, or removes it. None can be undone from here.")
                }
            }
        }
        .navigationTitle(radio.fleet.count > 1 ? radioName : "Device Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(hasChanges ? "Save" : "Saved") { requestSave() }
                    .fontWeight(.semibold)
                    .disabled(!hasChanges)
            }
        }
        .safeAreaInset(edge: .top) {
            if let savedNote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(savedNote).font(.footnote)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
            }
        }
        .confirmationDialog("Sleep is on", isPresented: $confirmSleepSave, titleVisibility: .visible) {
            Button("Save and Let It Sleep", role: .destructive) { performSave() }
            Button("Turn Sleep Off, Then Save") { powerSaving = false; performSave() }
        } message: {
            Text("After saving, this radio turns Bluetooth off and Hops can't reach it until you press its button.")
        }
        .confirmationDialog("Transmit is off", isPresented: $confirmTxOffSave, titleVisibility: .visible) {
            Button("Save — Listen Only", role: .destructive) { performSave() }
            Button("Turn Transmit On, Then Save") { txEnabled = true; performSave() }
        } message: {
            Text("This radio will only listen: nothing you send through it reaches the mesh, and nobody can confirm anything to it.")
        }
        .onAppear {
            let num = nodeNum ?? radio.myNodeNum
            if let entry = radio.fleet.first(where: { $0.nodeNum == num }) {
                nickname = entry.nickname
                location = entry.locationTag
            }
            radio.requestAllModuleConfigs(via: target)
            radio.requestConfig(.deviceConfig, via: target)
            radio.requestConfig(.powerConfig, via: target)
            radio.requestConfig(.networkConfig, via: target)
            radio.requestConfig(.loraConfig, via: target)
            radio.requestConfig(.securityConfig, via: target)
            syncAll()
        }
        // Read-backs trickle in for seconds after the screen opens (ten
        // requests). Only a section's *first* arrival fills the form;
        // later replies must never overwrite what the user is editing —
        // that is exactly what reverted saved toggles before.
        .onChange(of: cfg) { old, new in
            if old.bluetooth == nil, new.bluetooth != nil { syncBluetooth() }
            if old.display == nil, new.display != nil { syncDisplay() }
            if old.position == nil, new.position != nil { syncPosition() }
            if old.telemetry == nil, new.telemetry != nil { syncTelemetry() }
            if old.device == nil, new.device != nil { syncDevice() }
            if old.power == nil, new.power != nil { syncPower() }
            if old.network == nil, new.network != nil { syncNetwork() }
            if old.lora == nil, new.lora != nil { syncLoRa() }
            if !old.modules.allKnown { syncModules() }
        }
        .onDisappear {
            let num = nodeNum ?? radio.myNodeNum
            if let entry = radio.fleet.first(where: { $0.nodeNum == num }), entry.nickname != nickname {
                radio.renameRadio(num, nickname: nickname)
            }
        }
    }

    private func moduleToggle(_ title: String, _ value: Binding<Bool?>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue ?? false },
                                    set: { value.wrappedValue = $0 }))
            .disabled(value.wrappedValue == nil)
    }

    // MARK: - Load

    private func syncAll() {
        syncBluetooth(); syncDisplay(); syncPosition(); syncTelemetry(); syncDevice(); syncModules()
        syncPower(); syncNetwork(); syncLoRa()
    }

    private func syncPower() {
        guard let power = cfg.power else { return }
        powerSaving = power.isPowerSaving
    }

    private func syncNetwork() {
        guard let network = cfg.network else { return }
        wifiEnabled = network.wifiEnabled
    }

    private func syncLoRa() {
        guard let lora = cfg.lora else { return }
        txEnabled = lora.txEnabled
    }

    private func syncDevice() {
        guard let device = cfg.device else { return }
        rebroadcastRaw = device.rebroadcastMode.rawValue
        ledHeartbeatDisabled = device.ledHeartbeatDisabled
        let secs = device.nodeInfoBroadcastSecs == 0 ? 10800 : Int(device.nodeInfoBroadcastSecs)
        nodeInfoSecs = Self.nodeInfoChoices.map(\.1).contains(secs) ? secs : 10800
    }

    private func syncBluetooth() {
        guard let bluetooth = cfg.bluetooth else { return }
        btEnabled = bluetooth.enabled
        btModeRaw = bluetooth.mode.rawValue
        if bluetooth.fixedPin > 0 { btFixedPin = String(bluetooth.fixedPin) }
    }

    private func syncDisplay() {
        guard let display = cfg.display else { return }
        screenOnSecs = Self.screenChoices.map(\.1).contains(Int(display.screenOnSecs)) ? Int(display.screenOnSecs) : 60
        unitsRaw = display.units.rawValue
        use12HClock = display.use12HClock
        flipScreen = display.flipScreen
        compassNorthTop = display.compassNorthTop
        wakeOnTapOrMotion = display.wakeOnTapOrMotion
    }

    private func syncPosition() {
        guard let position = cfg.position else { return }
        gpsModeRaw = position.gpsMode.rawValue
        var secs = Int(position.positionBroadcastSecs)
        if secs >= 31_536_000 { secs = Self.never }
        broadcastSecs = Self.positionChoices.map(\.1).contains(secs) ? secs : 900
        smartEnabled = position.positionBroadcastSmartEnabled
        if position.broadcastSmartMinimumDistance > 0 { smartMinDistance = Int(position.broadcastSmartMinimumDistance) }
        if position.broadcastSmartMinimumIntervalSecs > 0 { smartMinSecs = Int(position.broadcastSmartMinimumIntervalSecs) }
        fixedPosition = position.fixedPosition
    }

    private func syncTelemetry() {
        guard let telemetry = cfg.telemetry else { return }
        deviceTelemetryEnabled = telemetry.deviceTelemetryEnabled
        var current = telemetry.deviceUpdateInterval == 0 ? 1800 : Int(telemetry.deviceUpdateInterval)
        if current >= 31_536_000 { current = Self.telemetryOff }   // a year or beyond reads back as Never
        if Self.telemetryChoices.map(\.1).contains(current) { deviceInterval = current }
        envEnabled = telemetry.environmentMeasurementEnabled
        powerEnabled = telemetry.powerMeasurementEnabled
        airEnabled = telemetry.airQualityEnabled
    }

    private func syncModules() {
        let m = cfg.modules
        if neighborInfoOn == nil, let c = m.neighborInfo { neighborInfoOn = c.enabled }
        if rangeTestOn == nil, let c = m.rangeTest { rangeTestOn = c.enabled }
        if storeForwardOn == nil, let c = m.storeForward { storeForwardOn = c.enabled }
        if detectionSensorOn == nil, let c = m.detectionSensor { detectionSensorOn = c.enabled }
        if paxcounterOn == nil, let c = m.paxcounter { paxcounterOn = c.enabled }
        if mqttOn == nil, let c = m.mqtt { mqttOn = c.enabled }
    }

    // MARK: - Save

    private func requestSave() {
        if powerSaving { confirmSleepSave = true; return }
        if !txEnabled, cfg.lora?.txEnabled == true { confirmTxOffSave = true; return }
        performSave()
    }

    private func performSave() {
        save()
        savedNote = "Saved — \(radioName) is restarting, back in about 20 seconds."
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            savedNote = nil
        }
    }

    private func save() {
        // Transactional: without begin/commit, the radio's save+reboot from
        // an early write races the later ones and drops them.
        radio.beginEditSettings(via: target)
        defer { radio.commitEditSettings(via: target) }

        var bluetooth = cfg.bluetooth ?? Config.BluetoothConfig()
        bluetooth.enabled = btEnabled
        bluetooth.mode = Config.BluetoothConfig.PairingMode(rawValue: btModeRaw) ?? .randomPin
        if btModeRaw == 1, let pin = UInt32(btFixedPin), pin >= 100_000 { bluetooth.fixedPin = pin }
        var btConfig = Config(); btConfig.bluetooth = bluetooth
        radio.applyConfig(btConfig, via: target)

        var displayConfig = Config(); displayConfig.display = formDisplay
        radio.applyConfig(displayConfig, via: target)

        if let power = formPower, power != cfg.power {
            var c = Config(); c.power = power
            radio.applyConfig(c, via: target)
        }
        if let network = formNetwork {
            var c = Config(); c.network = network
            radio.applyConfig(c, via: target)
        }
        // Transmit: written on top of the radio's full LoRa section so
        // nothing else in it moves.
        if var lora = cfg.lora, lora.txEnabled != txEnabled {
            lora.txEnabled = txEnabled
            var c = Config(); c.lora = lora
            radio.applyConfig(c, via: target)
        }

        var positionConfig = Config(); positionConfig.position = formPosition
        radio.applyConfig(positionConfig, via: target)

        var moduleConfig = ModuleConfig(); moduleConfig.telemetry = formTelemetry
        radio.applyModuleConfig(moduleConfig, via: target)

        // Device config only ever writes on top of the radio's own values —
        // a blank baseline would wipe the role and other fields.
        if let device = formDevice {
            var deviceWrite = Config(); deviceWrite.device = device
            radio.applyConfig(deviceWrite, via: target)
        }

        let m = formModules
        if let c = m.neighborInfo { var mc = ModuleConfig(); mc.neighborInfo = c; radio.applyModuleConfig(mc, via: target) }
        if let c = m.rangeTest { var mc = ModuleConfig(); mc.rangeTest = c; radio.applyModuleConfig(mc, via: target) }
        if let c = m.storeForward { var mc = ModuleConfig(); mc.storeForward = c; radio.applyModuleConfig(mc, via: target) }
        if let c = m.detectionSensor { var mc = ModuleConfig(); mc.detectionSensor = c; radio.applyModuleConfig(mc, via: target) }
        if let c = m.paxcounter { var mc = ModuleConfig(); mc.paxcounter = c; radio.applyModuleConfig(mc, via: target) }
        if let c = m.mqtt { var mc = ModuleConfig(); mc.mqtt = c; radio.applyModuleConfig(mc, via: target) }
    }
}
