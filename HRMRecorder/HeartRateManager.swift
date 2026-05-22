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

    /// One connected (or connecting) strap. The app can hold several at once;
    /// the scalar `@Published` properties below mirror whichever is `primary`
    /// so existing single-strap UI binds unchanged.
    struct ConnectedDevice: Identifiable {
        let id: UUID                       // CBPeripheral.identifier
        var peripheral: CBPeripheral
        var name: String
        var state: State = .connecting
        var heartRate = 0
        var sensorContact: Bool?
        var energyKJ: Int?
        var lastUpdate: Date?
        var manufacturer: String?
        var model: String?
        var firmware: String?
        var bodyLocation: String?
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var deviceName = "—"
    @Published private(set) var heartRate = 0
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

    /// Connected/connecting straps other than the primary, name-sorted for a
    /// stable list. The primary strap drives the big BPM display; these
    /// surface as a compact connection-status list.
    var secondaryDevices: [ConnectedDevice] {
        devices.values
            .filter { $0.id != primaryDeviceID }
            .sorted { $0.name < $1.name }
    }

    /// UUIDs of straps currently connected/connecting (for picker checkmarks).
    var connectedDeviceIDs: Set<UUID> { Set(devices.keys) }

    /// True once at least one strap is connected/connecting.
    var hasDevice: Bool { !devices.isEmpty }

    /// True if any strap is remembered (so a scan will silently reconnect it
    /// and the picker should not nag the user).
    var hasRememberedStrap: Bool { !preferredDeviceIDs.isEmpty }

    /// Live results of an in-progress device scan (sorted strongest signal first).
    @Published private(set) var discoveredDevices: [Device] = []

    @Published private(set) var isRecording = false
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionSampleCount = 0

    /// All connected/connecting straps, keyed by peripheral UUID. The scalar
    /// `@Published` properties mirror `primaryDeviceID`'s entry so single-strap
    /// UI is unchanged; secondary straps surface in the multi-strap UI (P3).
    @Published private(set) var devices: [UUID: ConnectedDevice] = [:]
    private var primaryDeviceID: UUID?

    private let db: HRDatabase
    private var central: CBCentralManager!
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

    /// UUIDs of remembered straps we're scanning to silently reconnect.
    private var autoConnectPreferred: Set<UUID> = []

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let bodySensorLocation = CBUUID(string: "2A38")
    private let disService = CBUUID(string: "180A")
    private let cManufacturer = CBUUID(string: "2A29")
    private let cModel = CBUUID(string: "2A24")
    private let cFirmware = CBUUID(string: "2A26")
    /// Invoked once after a session is closed (cold path only — never the
    /// ~1 Hz `ingest()` path). `AppModel` wires this to `SyncUploader` so a
    /// finished recording opportunistically uploads. A nil/throwing sink
    /// must never affect recording.
    var onSessionClosed: (() -> Void)?

    private let preferredDeviceKey = "preferredDeviceUUID"      // legacy single
    private let preferredDevicesKey = "preferredDeviceUUIDs"    // set of UUIDs
    private let activeSessionKey = "activeSessionID"

    /// Remembered straps to silently reconnect. Migrates the old single-key
    /// value once so an upgrading user keeps their strap.
    private var preferredDeviceIDs: Set<String> {
        get {
            if let arr = UserDefaults.standard.array(forKey: preferredDevicesKey) as? [String] {
                return Set(arr)
            }
            if let one = UserDefaults.standard.string(forKey: preferredDeviceKey) {
                return [one]                                   // legacy fallback
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: preferredDevicesKey)
            UserDefaults.standard.removeObject(forKey: preferredDeviceKey)
        }
    }

    /// Copy the primary strap's live values into the scalar `@Published`
    /// mirror (or reset to the disconnected defaults when none). Called on
    /// every `devices` mutation so the existing single-strap UI is unchanged.
    ///
    /// Also keeps the Live Activity / big-BPM display attached to a *working*
    /// strap: if the current primary has dropped (not `.connected`) but
    /// another strap still is, the connected one is promoted. We only
    /// promote into the primary slot — we never demote a still-connected
    /// primary back to secondary when an old strap reconnects (avoids
    /// flap on a flaky monitor). Sort by name so the choice between two
    /// connected secondaries is deterministic.
    private func refreshPrimaryMirror() {
        let currentPrimary = primaryDeviceID.flatMap { devices[$0] }
        if currentPrimary == nil || currentPrimary?.state != .connected {
            let connectedAlt = devices.values
                .filter { $0.state == .connected }
                .sorted { $0.name < $1.name }
                .first
            if let alt = connectedAlt {
                primaryDeviceID = alt.id
            } else if currentPrimary == nil {
                primaryDeviceID = devices.values.first?.id
            }
        }
        guard let d = primaryDeviceID.flatMap({ devices[$0] }) else {
            deviceName = "—"; heartRate = 0
            sensorContact = nil; energyKJ = nil; lastUpdate = nil
            manufacturer = nil; model = nil; firmware = nil; bodyLocation = nil
            return
        }
        deviceName = d.name
        heartRate = d.heartRate
        sensorContact = d.sensorContact
        energyKJ = d.energyKJ
        lastUpdate = d.lastUpdate
        manufacturer = d.manufacturer
        model = d.model
        firmware = d.firmware
        bodyLocation = d.bodyLocation
    }

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
        } else {
            NSLog("[LiveActivity] iOS < 16.2 — Live Activity unavailable on this device")
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
        onSessionClosed?()   // opportunistic sync (cold path; best-effort)
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
        autoConnectPreferred = []
        seen.removeAll()
        discoveredDevices = []
        guard central.state == .poweredOn else { return }
        central.stopScan()
        state = .scanning
        central.scanForPeripherals(
            withServices: [hrService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Connect to a user-chosen strap and remember it. Additive: picking
    /// another strap *adds* it (record several at once / keep a backup);
    /// works the same while recording — the new strap joins the same session.
    /// Single-strap users who only ever pick one see unchanged behavior.
    func select(_ device: Device) {
        guard let p = seen[device.id] else { return }
        preferredDeviceIDs.insert(device.id.uuidString)
        connect(p)
    }

    /// Drop one strap: disconnect it, stop remembering it, and remove it.
    func forget(_ id: UUID) {
        if let d = devices[id] { central.cancelPeripheralConnection(d.peripheral) }
        devices[id] = nil
        if primaryDeviceID == id { primaryDeviceID = nil }
        preferredDeviceIDs.remove(id.uuidString)
        refreshPrimaryMirror()      // promotes a new primary or resets scalars
    }

    /// Drop all saved straps and go back to picking one.
    func forgetDevice() {
        preferredDeviceIDs = []
        for d in devices.values { central.cancelPeripheralConnection(d.peripheral) }
        devices = [:]
        primaryDeviceID = nil
        refreshPrimaryMirror()      // resets scalars (deviceName → "—")
        startDeviceScan()
    }

    // MARK: - Connection establishment

    /// On power-on / state restoration: reconnect a restored peripheral,
    /// silently reconnect the remembered strap, or wait for the user to pick.
    private func autoConnectOrScan() {
        guard central.state == .poweredOn else { return }

        // Reconnect every peripheral the system restored to us (not just one).
        for p in devices.values.map(\.peripheral) { connect(p) }

        let remembered = Set(preferredDeviceIDs.compactMap(UUID.init(uuidString:)))
        var pending = remembered.subtracting(devices.keys)
        if pending.isEmpty {
            if devices.isEmpty { startDeviceScan() }   // nothing chosen — pick
            return
        }
        for p in central.retrievePeripherals(withIdentifiers: Array(pending))
        where pending.contains(p.identifier) {
            connect(p); pending.remove(p.identifier)
        }
        for p in central.retrieveConnectedPeripherals(withServices: [hrService])
        where pending.contains(p.identifier) {
            connect(p); pending.remove(p.identifier)
        }
        // Remaining remembered straps aren't immediately retrievable — scan
        // and grab each as it advertises, without bothering the user.
        if !pending.isEmpty {
            autoConnectPreferred = pending
            state = .scanning
            central.scanForPeripherals(withServices: [hrService], options: nil)
        }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        p.delegate = self
        let name = p.name ?? "Heart-Rate Strap"
        var d = devices[p.identifier]
            ?? ConnectedDevice(id: p.identifier, peripheral: p, name: name)
        d.peripheral = p
        d.name = name
        d.state = .connecting
        d.manufacturer = nil        // clear stale identity until re-read
        d.model = nil
        d.firmware = nil
        d.bodyLocation = nil
        devices[p.identifier] = d
        if primaryDeviceID == nil { primaryDeviceID = p.identifier }
        state = .connecting
        refreshPrimaryMirror()
        central.connect(p, options: nil)
    }

    /// Write whatever sensor identity we currently know: one row per strap in
    /// `devices` (so per-sample attribution resolves), plus the primary strap
    /// onto the session row (the session-level label, unchanged). Safe to call
    /// repeatedly — partial reads accumulate via COALESCE in the DB layer.
    private func persistDeviceInfo() {
        for d in devices.values {
            db.setDevice(id: d.id.uuidString,
                         name: d.name == "—" ? nil : d.name,
                         manufacturer: d.manufacturer,
                         model: d.model,
                         firmware: d.firmware,
                         bodyLocation: d.bodyLocation)
        }
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
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] else { return }
        for p in restored {                       // ALL straps, not just first
            p.delegate = self
            let name = p.name ?? "Heart-Rate Strap"
            devices[p.identifier] = ConnectedDevice(id: p.identifier,
                                                    peripheral: p, name: name)
            if primaryDeviceID == nil { primaryDeviceID = p.identifier }
        }
        refreshPrimaryMirror()
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        seen[id] = peripheral

        // Reconnecting a remembered strap: take it the moment it appears.
        if autoConnectPreferred.contains(id) {
            autoConnectPreferred.remove(id)
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
        devices[peripheral.identifier]?.name = peripheral.name ?? "Heart-Rate Strap"
        refreshPrimaryMirror()
        peripheral.discoverServices([hrService, disService])
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        devices[peripheral.identifier]?.state = .disconnected
        state = .disconnected
        refreshPrimaryMirror()
        autoConnectOrScan()
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        let id = peripheral.identifier
        devices[id]?.state = .disconnected
        state = .disconnected
        // Strap dropped (out of range, electrodes dried). Issue a pending
        // connect for every still-tracked/remembered strap — CoreBluetooth
        // honors it in the background and resumes the active recording
        // session automatically when the strap returns. This per-strap
        // resilience is what makes a backup strap actually back you up.
        if devices[id] != nil || preferredDeviceIDs.contains(id.uuidString) {
            central.connect(peripheral, options: nil)
            devices[id]?.state = .connecting
            state = .connecting
        }
        refreshPrimaryMirror()
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            devices[peripheral.identifier]?.state = .disconnected
            state = .disconnected
            refreshPrimaryMirror()
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
        if !services.contains(where: { $0.uuid == hrService }) {
            devices[peripheral.identifier]?.state = .disconnected
            state = .disconnected
            refreshPrimaryMirror()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case hrMeasurement:
                peripheral.setNotifyValue(true, for: ch)
                devices[peripheral.identifier]?.state = .connected
                state = .connected
                refreshPrimaryMirror()
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
        let id = peripheral.identifier
        switch characteristic.uuid {
        case hrMeasurement:
            ingest(data, from: peripheral)
        case cManufacturer:
            devices[id]?.manufacturer = decodeString(data)
            refreshPrimaryMirror(); persistDeviceInfo()
        case cModel:
            devices[id]?.model = decodeString(data)
            refreshPrimaryMirror(); persistDeviceInfo()
        case cFirmware:
            devices[id]?.firmware = decodeString(data)
            refreshPrimaryMirror(); persistDeviceInfo()
        case bodySensorLocation:
            devices[id]?.bodyLocation = Self.bodyLocationName(data.first)
            refreshPrimaryMirror(); persistDeviceInfo()
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

    /// Parse a Heart Rate Measurement packet (Bluetooth GATT 0x2A37) from a
    /// specific strap and route it to that strap's `ConnectedDevice` entry.
    private func ingest(_ data: Data, from peripheral: CBPeripheral) {
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
        let devID = peripheral.identifier
        if devices[devID] != nil {
            devices[devID]!.heartRate = bpm
            devices[devID]!.sensorContact = contact
            devices[devID]!.energyKJ = energy
            devices[devID]!.lastUpdate = now
        }
        refreshPrimaryMirror()

        if isRecording, let sid = sessionID {
            // Stamp each sample with its source strap so a session spanning
            // several straps stays attributable in the CSV. Single-strap
            // output is unchanged: export COALESCEs the devices row over the
            // session row to the same identity (first 12 cols byte-identical).
            db.insertSample(sessionID: sid, date: now, bpm: bpm,
                            rr: rr, contact: contact, energyKJ: energy,
                            deviceID: devID.uuidString)
            sessionSampleCount += 1
            if #available(iOS 16.2, *), devID == primaryDeviceID {
                liveActivity.update(bpm: bpm, contact: contact, now: now,
                                    secondaryBPMs: secondaryDevices
                                        .map(\.heartRate).filter { $0 > 0 })
            }
        }
    }
}
