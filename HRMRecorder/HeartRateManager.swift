import Foundation
import CoreBluetooth
import UIKit

/// Connects to a BLE heart-rate strap (Garmin HRM-Pro+ and any sensor that
/// exposes the standard Heart Rate Service 0x180D), parses the Heart Rate
/// Measurement characteristic in real time, and — while recording — writes
/// every notification straight to SQLite.
///
/// The central runs on the main queue, so all `@Published` mutations and DB
/// hand-offs already happen on the main thread.
///
/// Background recording survives three escalating cases:
///   1. Screen off / app suspended — `bluetooth-central` keeps notifications
///      flowing while the strap stays connected.
///   2. App killed by the system — CoreBluetooth state restoration
///      (`CBCentralManagerOptionRestoreIdentifierKey`) relaunches the app in
///      the background on the next strap event.
///   3. Process restarted for any reason — the active session id is persisted
///      to `UserDefaults`, so `init` resumes recording into the same session
///      and no samples are lost once the strap reconnects.
final class HeartRateManager: NSObject, ObservableObject {

    enum State: Equatable {
        case poweredOff
        case unauthorized
        case scanning
        case connecting
        case connected
        case disconnected

        var label: String {
            switch self {
            case .poweredOff:   return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission denied"
            case .scanning:     return "Searching for straps…"
            case .connecting:   return "Connecting…"
            case .connected:    return "Connected"
            case .disconnected: return "Not connected"
            }
        }
    }

    /// A strap seen during a scan, offered to the user to pick from.
    struct Device: Identifiable, Hashable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var deviceName = "—"
    @Published private(set) var heartRate = 0
    @Published private(set) var rrIntervals: [Int] = []
    @Published private(set) var sensorContact: Bool?
    @Published private(set) var energyKJ: Int?
    @Published private(set) var lastUpdate: Date?

    /// Sensor identity, read from the Device Information Service (0x180A) and
    /// the HR service's Body Sensor Location characteristic on connect.
    @Published private(set) var manufacturer: String?
    @Published private(set) var model: String?
    @Published private(set) var firmware: String?
    @Published private(set) var bodyLocation: String?

    /// Human-readable sensor summary, e.g. "Garmin HRM-Pro+ · Chest".
    var sensorSummary: String? {
        let parts = [[manufacturer, model].compactMap { $0 }.joined(separator: " "),
                     bodyLocation].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Live results of an in-progress device scan (sorted strongest signal first).
    @Published private(set) var discoveredDevices: [Device] = []

    @Published private(set) var isRecording = false
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionSampleCount = 0

    private let db: HRDatabase
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var sessionID: String?

    /// Lock-screen / Dynamic Island Live Activity, alive only while recording.
    /// Best-effort glanceable UI — its failures never affect capture.
    private let liveActivity = LiveActivityController()

    /// A presentable strap name for the Live Activity (`deviceName` is "—"
    /// until a strap connects, e.g. during an early session resume).
    private var liveActivityDeviceName: String {
        deviceName == "—" ? "Heart-Rate Strap" : deviceName
    }

    /// Strong references to peripherals seen while scanning; CoreBluetooth
    /// releases any peripheral we don't retain, which would break `select`.
    private var seen: [UUID: CBPeripheral] = [:]

    /// When a strap was previously chosen, reconnect to it without prompting.
    private var autoConnectPreferred = false

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let bodySensorLocation = CBUUID(string: "2A38")
    private let disService = CBUUID(string: "180A")
    private let cManufacturer = CBUUID(string: "2A29")
    private let cModel = CBUUID(string: "2A24")
    private let cFirmware = CBUUID(string: "2A26")
    private let preferredDeviceKey = "preferredDeviceUUID"
    private let activeSessionKey = "activeSessionID"

    init(db: HRDatabase) {
        self.db = db
        super.init()
        resumeActiveSessionIfNeeded()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "HRMRecorderCentral",
                CBCentralManagerOptionShowPowerAlertKey: true
            ])
    }

    // MARK: - Recording control

    func startRecording() {
        guard !isRecording else { return }
        let name = deviceName == "—" ? nil : deviceName
        let id = db.startSession(deviceName: name)
        sessionID = id
        UserDefaults.standard.set(id, forKey: activeSessionKey)
        sessionSampleCount = 0
        sessionStartedAt = Date()
        isRecording = true
        persistDeviceInfo()                               // capture identity if already connected
        if #available(iOS 16.2, *) {
            liveActivity.start(deviceName: liveActivityDeviceName,
                               sessionStartedAt: sessionStartedAt ?? Date(),
                               bpm: heartRate, contact: sensorContact)
        }
        UIApplication.shared.isIdleTimerDisabled = true   // keep screen awake in foreground
    }

    func stopRecording() {
        guard isRecording, let id = sessionID else { return }
        db.endSession(id)
        UserDefaults.standard.removeObject(forKey: activeSessionKey)
        isRecording = false
        if #available(iOS 16.2, *) { liveActivity.end() }
        sessionID = nil
        sessionStartedAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Restore an interrupted session after a process restart so capture
    /// continues into the same session once the strap reconnects.
    private func resumeActiveSessionIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: activeSessionKey),
              let s = db.session(id: id), s.endedAt == nil else {
            UserDefaults.standard.removeObject(forKey: activeSessionKey)
            return
        }
        sessionID = id
        isRecording = true
        sessionStartedAt = s.startedAt
        sessionSampleCount = s.sampleCount
        if #available(iOS 16.2, *) {
            liveActivity.adopt(deviceName: liveActivityDeviceName,
                               sessionStartedAt: s.startedAt,
                               bpm: heartRate, contact: sensorContact)
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Device selection

    /// Begin (or restart) a scan that populates `discoveredDevices` for the
    /// user to choose from. Does not auto-connect.
    func startDeviceScan() {
        autoConnectPreferred = false
        seen.removeAll()
        discoveredDevices = []
        guard central.state == .poweredOn else { return }
        central.stopScan()
        state = .scanning
        central.scanForPeripherals(
            withServices: [hrService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Connect to a user-chosen strap and remember it for next launch.
    func select(_ device: Device) {
        guard let p = seen[device.id] else { return }
        UserDefaults.standard.set(device.id.uuidString, forKey: preferredDeviceKey)
        connect(p)
    }

    /// Drop the saved strap and go back to picking one.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: preferredDeviceKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        deviceName = "—"
        startDeviceScan()
    }

    // MARK: - Connection establishment

    /// On power-on / state restoration: reconnect a restored peripheral,
    /// silently reconnect the remembered strap, or wait for the user to pick.
    private func autoConnectOrScan() {
        guard central.state == .poweredOn else { return }

        if let p = peripheral {                       // restored by the system
            connect(p)
            return
        }
        if let uuidString = UserDefaults.standard.string(forKey: preferredDeviceKey),
           let uuid = UUID(uuidString: uuidString) {
            if let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                connect(p)
                return
            }
            if let p = central.retrieveConnectedPeripherals(withServices: [hrService])
                .first(where: { $0.identifier == uuid }) {
                connect(p)
                return
            }
            // Remembered strap not immediately retrievable — scan and grab it
            // as soon as it advertises, without bothering the user.
            autoConnectPreferred = true
            state = .scanning
            central.scanForPeripherals(withServices: [hrService], options: nil)
            return
        }
        // Nothing chosen yet — let the user pick.
        startDeviceScan()
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "Heart-Rate Strap"
        manufacturer = nil          // clear stale identity until re-read
        model = nil
        firmware = nil
        bodyLocation = nil
        state = .connecting
        central.connect(p, options: nil)
    }

    /// Write whatever sensor identity we currently know onto the active
    /// session. Safe to call repeatedly — partial reads accumulate via
    /// COALESCE in the DB layer.
    private func persistDeviceInfo() {
        guard let id = sessionID else { return }
        db.setSessionDevice(sessionID: id,
                            manufacturer: manufacturer,
                            model: model,
                            firmware: firmware,
                            bodyLocation: bodyLocation)
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    autoConnectOrScan()
        case .poweredOff:   state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .resetting, .unknown, .unsupported:
            state = .disconnected
        @unknown default:
            state = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first {
            peripheral = p
            p.delegate = self
            deviceName = p.name ?? "Heart-Rate Strap"
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        seen[id] = peripheral

        // Reconnecting to the remembered strap: take it the moment it appears.
        if autoConnectPreferred,
           let saved = UserDefaults.standard.string(forKey: preferredDeviceKey),
           saved == id.uuidString {
            autoConnectPreferred = false
            connect(peripheral)
            return
        }

        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown strap (\(id.uuidString.prefix(8)))"
        let device = Device(id: id, name: name, rssi: RSSI.intValue)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == id }) {
            discoveredDevices[idx].rssi = device.rssi
        } else {
            discoveredDevices.append(device)
        }
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        deviceName = peripheral.name ?? "Heart-Rate Strap"
        peripheral.discoverServices([hrService, disService])
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        state = .disconnected
        autoConnectOrScan()
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        state = .disconnected
        // Strap dropped (out of range, electrodes dried). Issue a pending
        // connect — CoreBluetooth honors it in the background and resumes the
        // active recording session automatically when the strap returns.
        if peripheral.identifier == self.peripheral?.identifier {
            central.connect(peripheral, options: nil)
            state = .connecting
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            state = .disconnected
            return
        }
        for service in services {
            switch service.uuid {
            case hrService:
                peripheral.discoverCharacteristics([hrMeasurement, bodySensorLocation],
                                                   for: service)
            case disService:
                peripheral.discoverCharacteristics([cManufacturer, cModel, cFirmware],
                                                   for: service)
            default:
                break
            }
        }
        if !services.contains(where: { $0.uuid == hrService }) { state = .disconnected }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case hrMeasurement:
                peripheral.setNotifyValue(true, for: ch)
                state = .connected
            case bodySensorLocation, cManufacturer, cModel, cFirmware:
                peripheral.readValue(for: ch)   // one-shot reads, identity is static
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case hrMeasurement:
            ingest(data)
        case cManufacturer:
            manufacturer = decodeString(data); persistDeviceInfo()
        case cModel:
            model = decodeString(data); persistDeviceInfo()
        case cFirmware:
            firmware = decodeString(data); persistDeviceInfo()
        case bodySensorLocation:
            bodyLocation = Self.bodyLocationName(data.first); persistDeviceInfo()
        default:
            break
        }
    }

    private func decodeString(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return s.isEmpty ? nil : s
    }

    /// Body Sensor Location characteristic (GATT 0x2A38) enumeration.
    private static func bodyLocationName(_ code: UInt8?) -> String? {
        switch code {
        case 0: return "Other"
        case 1: return "Chest"
        case 2: return "Wrist"
        case 3: return "Finger"
        case 4: return "Hand"
        case 5: return "Ear Lobe"
        case 6: return "Foot"
        default: return nil
        }
    }

    /// Parse a Heart Rate Measurement packet (Bluetooth GATT 0x2A37).
    private func ingest(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }

        let flags = bytes[0]
        var i = 1

        let bpm: Int
        if flags & 0x01 != 0 {                      // 16-bit heart rate
            guard i + 1 < bytes.count else { return }
            bpm = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        } else {                                    // 8-bit heart rate
            bpm = Int(bytes[i])
            i += 1
        }

        let contact: Bool? = (flags & 0x04 != 0) ? (flags & 0x02 != 0) : nil

        var energy: Int?
        if flags & 0x08 != 0, i + 1 < bytes.count {
            energy = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        }

        var rr: [Int] = []
        if flags & 0x10 != 0 {
            while i + 1 < bytes.count {
                let raw = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
                i += 2
                rr.append(Int((Double(raw) / 1024.0) * 1000.0))   // 1/1024 s → ms
            }
        }

        let now = Date()
        heartRate = bpm
        rrIntervals = rr
        sensorContact = contact
        energyKJ = energy
        lastUpdate = now

        if isRecording, let id = sessionID {
            db.insertSample(sessionID: id, date: now, bpm: bpm,
                            rr: rr, contact: contact, energyKJ: energy)
            sessionSampleCount += 1
            if #available(iOS 16.2, *) {
                liveActivity.update(bpm: bpm, contact: contact, now: now)
            }
        }
    }
}
