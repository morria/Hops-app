import Foundation
import CoreBluetooth
import OSLog

/// What RadioManager needs from the Bluetooth layer — implemented by
/// `BLECentral` on device and by a scripted mock in tests (fleet phase 6).
protocol RadioTransport: AnyObject {
    var onEvent: (@MainActor (BLECentral.Event) -> Void)? { get set }
    func activate()
    func startScan()
    func stopScan()
    func connect(to ids: Set<UUID>)
    func forget(_ id: UUID)
    func retryFresh(id: UUID)
    func connectDiscovered(id: UUID)
    func disconnect(id: UUID, userInitiated: Bool)
    func disconnectAll(userInitiated: Bool)
    func write(id: UUID, _ data: Data)
    func drain(id: UUID)
}

extension BLECentral: RadioTransport {}

/// One CBCentralManager for the whole fleet (docs/MULTI_RADIO.md §2.2):
/// scanning, pending connects for every paired radio, state restoration —
/// and a `BLELink` per connected peripheral for the GATT plumbing. Events
/// carry the peripheral id so RadioManager can route them to the right
/// link. Several radios may be attached at once.
final class BLECentral: NSObject {

    enum UUIDs {
        static let service = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
        static let toRadio = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
        static let fromRadio = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
        static let fromNum = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    enum Event {
        case bluetoothState(CBManagerState)
        case discovered(Discovered)
        case linkReady(UUID)                     // connected + FROMNUM notify confirmed
        case disconnected(UUID, wasUserInitiated: Bool)
        case frame(UUID, Data)                   // one FromRadio protobuf frame
        case drainComplete(UUID)                 // FROMRADIO read returned empty
        case bondLost(UUID)
        case writeError(UUID, String)
        case writeStalled(UUID, pending: Int)
    }

    var onEvent: (@MainActor (Event) -> Void)?

    fileprivate let log = Logger(subsystem: "com.w2asm.hops", category: "ble")
    fileprivate let queue = DispatchQueue(label: "com.w2asm.hops.ble")
    /// Created lazily by `activate()`: instantiating a CBCentralManager is
    /// what triggers the system Bluetooth prompt (TODO 178).
    private var central: CBCentralManager?
    /// Peripherals we hold or are connecting to, by id.
    private var links: [UUID: BLELink] = [:]
    /// Ids we keep a pending connect armed for (the fleet on this device).
    private var wanted: Set<UUID> = []
    /// Seen while scanning (pairing) — needed to connect by id later.
    private var known: [UUID: CBPeripheral] = [:]
    private var restored: [UUID: CBPeripheral] = [:]
    private var userInitiated: Set<UUID> = []
    private var scanAssistUntil = Date.distantPast

    func activate() {
        queue.sync {
            guard central == nil else { return }
            central = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.w2asm.hops.central",
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        }
    }

    private var poweredCentral: CBCentralManager? {
        guard let central, central.state == .poweredOn else { return nil }
        return central
    }

    fileprivate func emit(_ event: Event) {
        Task { @MainActor [onEvent] in onEvent?(event) }
    }

    // MARK: - Public API (any queue)

    func startScan() {
        queue.async {
            guard let central = self.poweredCentral else { return }
            central.scanForPeripherals(withServices: [UUIDs.service],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func stopScan() {
        queue.async { self.poweredCentral?.stopScan() }
    }

    /// Arm (or re-arm) a pending connect for every id. iOS connects each one
    /// the moment it advertises; nothing is cancelled in favour of another.
    func connect(to ids: Set<UUID>) {
        queue.async {
            self.wanted.formUnion(ids)
            guard let central = self.poweredCentral else { return }
            var needScan = false
            for id in ids where self.links[id] == nil {
                self.userInitiated.remove(id)
                if let p = self.restored.removeValue(forKey: id) {
                    let link = self.adopt(p)
                    if p.state == .connected { link.discover() } else { central.connect(p) }
                } else if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                    self.adopt(p)
                    central.connect(p)          // pending connect: never expires
                    needScan = true
                } else {
                    needScan = true
                }
            }
            // Scan-assist: an advertisement can beat the pending connect;
            // either path wins. Time-boxed, skipped in Battery Saver.
            if needScan, !PowerMode.saver {
                self.scanAssistUntil = Date().addingTimeInterval(45)
                central.scanForPeripherals(withServices: [UUIDs.service], options: nil)
                self.queue.asyncAfter(deadline: .now() + 45) {
                    if Date() >= self.scanAssistUntil { self.poweredCentral?.stopScan() }
                }
            }
        }
    }

    /// Stop wanting an id: cancels its connection and any pending connect.
    func forget(_ id: UUID) {
        queue.async {
            self.wanted.remove(id)
            self.userInitiated.insert(id)
            if let link = self.links[id] { self.central?.cancelPeripheralConnection(link.peripheral) }
            else if let p = self.known[id] ?? self.central?.retrievePeripherals(withIdentifiers: [id]).first {
                self.central?.cancelPeripheralConnection(p)
            }
        }
    }

    /// Watchdog escalation for one id: drop the possibly-stale attempt and
    /// retrieve fresh.
    func retryFresh(id: UUID) {
        queue.async {
            if let link = self.links[id] {
                self.central?.cancelPeripheralConnection(link.peripheral)   // didDisconnect re-arms
            } else if let central = self.poweredCentral,
                      let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                self.adopt(p)
                central.connect(p)
            }
        }
    }

    func connectDiscovered(id: UUID) {
        queue.async {
            guard let p = self.known[id], let central = self.poweredCentral else { return }
            self.wanted.insert(id)
            self.userInitiated.remove(id)
            central.stopScan()
            self.adopt(p)
            central.connect(p)
        }
    }

    func disconnect(id: UUID, userInitiated: Bool) {
        queue.async {
            if userInitiated { self.userInitiated.insert(id) }
            if let link = self.links[id] { self.central?.cancelPeripheralConnection(link.peripheral) }
        }
    }

    func disconnectAll(userInitiated: Bool) {
        queue.async {
            for (id, link) in self.links {
                if userInitiated { self.userInitiated.insert(id) }
                self.central?.cancelPeripheralConnection(link.peripheral)
            }
        }
    }

    func write(id: UUID, _ data: Data) {
        queue.async { self.links[id]?.write(data) }
    }

    func drain(id: UUID) {
        queue.async { self.links[id]?.drainLocked() }
    }

    @discardableResult
    private func adopt(_ p: CBPeripheral) -> BLELink {
        if let existing = links[p.identifier], existing.peripheral === p { return existing }
        let link = BLELink(peripheral: p, central: self)
        links[p.identifier] = link
        return link
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.bluetoothState(central.state))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a BLE event; it may hand back several.
        for p in (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? [] {
            restored[p.identifier] = p
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        known[peripheral.identifier] = peripheral
        // Seeing a wanted radio IS the signal to connect.
        if wanted.contains(peripheral.identifier), links[peripheral.identifier] == nil
            || links[peripheral.identifier]?.peripheral.state == .disconnected {
            adopt(peripheral)
            central.connect(peripheral)
            return
        }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Meshtastic"
        emit(.discovered(Discovered(id: peripheral.identifier, name: name, rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let link = links[peripheral.identifier] else { return }
        // Scan-assist for this radio is done; others may still need it.
        if links.values.allSatisfy({ $0.peripheral.state == .connected }) { central.stopScan() }
        link.discover()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("connect failed: \(error?.localizedDescription ?? "unknown")")
        links[peripheral.identifier] = nil
        emit(.disconnected(peripheral.identifier, wasUserInitiated: false))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        links[id] = nil
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            emit(.bondLost(id))
            return
        }
        emit(.disconnected(id, wasUserInitiated: userInitiated.contains(id)))
    }
}

// MARK: - One connected radio

/// GATT plumbing for one peripheral: characteristic discovery, the
/// serialized TORADIO write pump with retry and stall watchdog, and the
/// FROMRADIO read-until-empty drain.
final class BLELink: NSObject {
    let peripheral: CBPeripheral
    private unowned let central: BLECentral
    private var toRadioChar: CBCharacteristic?
    private var fromRadioChar: CBCharacteristic?
    private var fromNumChar: CBCharacteristic?
    private var draining = false
    private var needsDrain = false
    private var writeQueue: [Data] = []
    private var writing = false
    private var writeAttempts = 0
    private var writeSerial = 0
    private static let writeStallSeconds = 10.0
    var id: UUID { peripheral.identifier }

    init(peripheral: CBPeripheral, central: BLECentral) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    fileprivate func discover() {
        peripheral.discoverServices([BLECentral.UUIDs.service])
    }

    fileprivate func write(_ data: Data) {
        writeQueue.append(data)
        pumpWrites()
        armStallWatchdog()
    }

    /// TODO 182: a TORADIO write whose completion never arrives would leave
    /// `writing` true forever and every later frame silently queued. Detect
    /// it, report it, reset the pump; a duplicate head frame is harmless.
    private func armStallWatchdog() {
        guard writing else { return }
        let serial = writeSerial
        central.queue.asyncAfter(deadline: .now() + Self.writeStallSeconds) {
            guard self.writing, self.writeSerial == serial, !self.writeQueue.isEmpty else { return }
            self.central.log.error("TORADIO write stalled; \(self.writeQueue.count) queued - resetting pump")
            self.central.emit(.writeStalled(self.id, pending: self.writeQueue.count))
            self.writing = false
            self.writeAttempts = 0
            self.pumpWrites()
            self.armStallWatchdog()
        }
    }

    private func pumpWrites() {
        guard !writing, let c = toRadioChar, peripheral.state == .connected,
              let next = writeQueue.first else { return }
        writing = true
        peripheral.writeValue(next, for: c, type: .withResponse)
    }

    private func finishCurrentWrite() {
        if !writeQueue.isEmpty { writeQueue.removeFirst() }
        writeAttempts = 0
        writing = false
        writeSerial += 1
        pumpWrites()
        armStallWatchdog()
    }

    fileprivate func drainLocked() {
        if draining { needsDrain = true; return }
        draining = true
        readNext()
    }

    private func readNext() {
        guard let c = fromRadioChar, peripheral.state == .connected else {
            draining = false
            return
        }
        peripheral.readValue(for: c)
    }

    private func isAuthError(_ error: Error) -> Bool {
        if let att = error as? CBATTError {
            return [.insufficientAuthentication, .insufficientEncryption, .insufficientAuthorization].contains(att.code)
        }
        if let cb = error as? CBError {
            return [.peerRemovedPairingInformation, .encryptionTimedOut].contains(cb.code)
        }
        return false
    }
}

extension BLELink: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BLECentral.UUIDs.service }) else {
            central.disconnect(id: id, userInitiated: false)
            return
        }
        peripheral.discoverCharacteristics([BLECentral.UUIDs.toRadio, BLECentral.UUIDs.fromRadio,
                                            BLECentral.UUIDs.fromNum], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLECentral.UUIDs.toRadio: toRadioChar = characteristic
            case BLECentral.UUIDs.fromRadio: fromRadioChar = characteristic
            case BLECentral.UUIDs.fromNum: fromNumChar = characteristic
            default: break
            }
        }
        guard toRadioChar != nil, fromRadioChar != nil, let fromNum = fromNumChar else {
            central.disconnect(id: id, userInitiated: false)
            return
        }
        // First-ever connect: this triggers the iOS pairing PIN sheet; the
        // notify-state callback is the bonding confirmation.
        peripheral.setNotifyValue(true, for: fromNum)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLECentral.UUIDs.fromNum else { return }
        if let error {
            central.log.error("notify failed: \(error.localizedDescription)")
            if isAuthError(error) { central.emit(.bondLost(id)) } else { central.disconnect(id: id, userInitiated: false) }
            return
        }
        central.emit(.linkReady(id))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            central.log.error("read error: \(error.localizedDescription)")
            if isAuthError(error) { central.emit(.bondLost(id)) }
            return
        }
        switch characteristic.uuid {
        case BLECentral.UUIDs.fromNum:
            drainLocked()   // doorbell: "data available"
        case BLECentral.UUIDs.fromRadio:
            let data = characteristic.value ?? Data()
            if data.isEmpty {
                draining = false
                if needsDrain {
                    needsDrain = false
                    drainLocked()
                } else {
                    central.emit(.drainComplete(id))
                }
            } else {
                central.emit(.frame(id, data))
                readNext()
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let att = error as? CBATTError, att.code == .insufficientResources, writeAttempts < 4 {
            writeAttempts += 1
            let delay = DispatchTimeInterval.milliseconds(120 * writeAttempts)
            central.log.warning("TORADIO busy, retry \(self.writeAttempts)")
            central.queue.asyncAfter(deadline: .now() + delay) {
                guard let c = self.toRadioChar, self.peripheral.state == .connected,
                      let current = self.writeQueue.first else {
                    self.writing = false
                    return
                }
                self.peripheral.writeValue(current, for: c, type: .withResponse)
            }
            return
        }
        if let error {
            central.log.error("write error: \(error.localizedDescription)")
            central.emit(.writeError(id, error.localizedDescription))
        }
        finishCurrentWrite()
    }
}
