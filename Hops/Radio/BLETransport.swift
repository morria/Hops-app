import Foundation
import CoreBluetooth
import OSLog

/// Raw BLE plumbing for the Meshtastic GATT service.
/// Owns the CBCentralManager; forwards decoded events to `RadioManager` on the main actor.
final class BLETransport: NSObject {

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
        case linkReady               // connected + FROMNUM notify confirmed
        case disconnected(wasUserInitiated: Bool)
        case frame(Data)             // one FromRadio protobuf frame
        case drainComplete           // FROMRADIO read returned empty
        case bondLost
    }

    var onEvent: (@MainActor (Event) -> Void)?

    private let log = Logger(subsystem: "com.w2asm.hops", category: "ble")
    private let queue = DispatchQueue(label: "com.w2asm.hops.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var toRadioChar: CBCharacteristic?
    private var fromRadioChar: CBCharacteristic?
    private var fromNumChar: CBCharacteristic?
    private var userInitiatedDisconnect = false
    private var draining = false
    private var needsDrain = false
    private var restoredPeripheral: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.w2asm.hops.central",
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    private func emit(_ event: Event) {
        Task { @MainActor [onEvent] in onEvent?(event) }
    }

    // MARK: - Public API (callable from any queue)

    func startScan() {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            self.central.scanForPeripherals(withServices: [UUIDs.service],
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func stopScan() {
        queue.async {
            if self.central.state == .poweredOn { self.central.stopScan() }
        }
    }

    private var known: [UUID: CBPeripheral] = [:]

    /// Retrieval-first reconnect: hand iOS the bonded identifier and let it connect the
    /// moment the radio advertises — no scanning. Falls back to a scan if retrieval fails.
    func connect(to id: UUID) {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            self.userInitiatedDisconnect = false
            if let restored = self.restoredPeripheral, restored.identifier == id {
                self.adopt(restored)
                if restored.state == .connected {
                    restored.discoverServices([UUIDs.service])
                } else {
                    self.central.connect(restored)
                }
                self.restoredPeripheral = nil
                return
            }
            if let target = self.central.retrievePeripherals(withIdentifiers: [id]).first {
                self.adopt(target)
                self.central.connect(target)   // pending connect: never expires
            } else {
                self.startScan()               // fallback: catch an advertisement
            }
        }
    }

    func connectDiscovered(id: UUID) {
        queue.async {
            guard let target = self.known[id] else { return }
            self.userInitiatedDisconnect = false
            self.central.stopScan()
            self.adopt(target)
            self.central.connect(target)
        }
    }

    func disconnect(userInitiated: Bool) {
        queue.async {
            self.userInitiatedDisconnect = userInitiated
            if let p = self.peripheral {
                self.central.cancelPeripheralConnection(p)
            }
        }
    }

    func write(_ data: Data) {
        queue.async {
            guard let p = self.peripheral, let c = self.toRadioChar else { return }
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    /// Kick (or coalesce) the read-until-empty drain loop.
    func drain() {
        queue.async { self.drainLocked() }
    }

    private func drainLocked() {
        if draining { needsDrain = true; return }
        draining = true
        readNext()
    }

    private func readNext() {
        guard let p = peripheral, let c = fromRadioChar, p.state == .connected else {
            draining = false
            return
        }
        p.readValue(for: c)
    }

    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        toRadioChar = nil
        fromRadioChar = nil
        fromNumChar = nil
        draining = false
        needsDrain = false
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.bluetoothState(central.state))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a BLE event on a restored peripheral.
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            restored.delegate = self
            restoredPeripheral = restored
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        known[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Meshtastic"
        emit(.discovered(Discovered(id: peripheral.identifier, name: name, rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        peripheral.discoverServices([UUIDs.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("connect failed: \(error?.localizedDescription ?? "unknown")")
        emit(.disconnected(wasUserInitiated: false))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        draining = false
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            emit(.bondLost)
            return
        }
        emit(.disconnected(wasUserInitiated: userInitiatedDisconnect))
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == UUIDs.service }) else {
            emit(.disconnected(wasUserInitiated: false))
            return
        }
        peripheral.discoverCharacteristics([UUIDs.toRadio, UUIDs.fromRadio, UUIDs.fromNum], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case UUIDs.toRadio: toRadioChar = characteristic
            case UUIDs.fromRadio: fromRadioChar = characteristic
            case UUIDs.fromNum: fromNumChar = characteristic
            default: break
            }
        }
        guard toRadioChar != nil, fromRadioChar != nil, let fromNum = fromNumChar else {
            emit(.disconnected(wasUserInitiated: false))
            return
        }
        // On a first-ever connect this triggers the iOS pairing PIN sheet; the
        // notify-state callback below is the bonding confirmation.
        peripheral.setNotifyValue(true, for: fromNum)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == UUIDs.fromNum else { return }
        if let error {
            log.error("notify failed: \(error.localizedDescription)")
            if isAuthError(error) { emit(.bondLost) } else { emit(.disconnected(wasUserInitiated: false)) }
            return
        }
        emit(.linkReady)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("read error: \(error.localizedDescription)")
            if isAuthError(error) { emit(.bondLost) }
            return
        }
        switch characteristic.uuid {
        case UUIDs.fromNum:
            // Doorbell: value is ignored, it just means "data available".
            drainLocked()
        case UUIDs.fromRadio:
            let data = characteristic.value ?? Data()
            if data.isEmpty {
                // Empty read is the end-of-queue sentinel.
                draining = false
                if needsDrain {
                    needsDrain = false
                    drainLocked()
                } else {
                    emit(.drainComplete)
                }
            } else {
                emit(.frame(data))
                readNext()
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("write error: \(error.localizedDescription)")
        }
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
