#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import os

// The central and its peripheral delegates deliver callbacks on the main queue.
public final class BluetoothReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let heartRateService = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")
    private var central: CBCentralManager?
    private var device: CBPeripheral?
    private var retry: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?
    private var retryDelay: TimeInterval = 5
    private var running = false
    // Set by a direct connection attempt and cleared once notifications run,
    // so an attempt that fails or times out falls back to a scan next time.
    private var preferScan = false
    private var scan = ScanDiagnostics()
    // `os.Logger`, not the app's Logger model. Read with:
    // log show --last 1h --predicate 'subsystem == "com.meetspike.hr"'
    private let log = os.Logger(subsystem: "com.meetspike.hr", category: "bluetooth")

    public override init() { super.init() }

    public var canListen: (() -> Bool)?
    private var listening: Bool { running && (canListen?() ?? true) }
    private var allowsDiscovery = true

    public var preferredID: UUID?
    public var onPaired: ((UUID) -> Void)?
    public var onStatus: ((BluetoothStatus) -> Void)?
    public var onReading: ((Int, Date) -> Void)?
    public var onPermission: ((BluetoothPermission) -> Void)?
    public var onScan: ((ScanDiagnostics) -> Void)?

    /// Reads the saved privacy decision without prompting.
    public static var permission: BluetoothPermission {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .notDetermined
        }
    }

    public func setRunning(_ shouldRun: Bool) {
        guard running != shouldRun else { return }
        running = shouldRun
        if shouldRun {
            if let central {
                centralManagerDidUpdateState(central)
            } else {
                createCentral()
            }
        } else {
            stop()
        }
    }

    private func createCentral() {
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.hersheyg.meetspike.hr.central"
        ])
        #else
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
    }

    #if os(iOS)
    /// Initialize the saved central so iOS can deliver or discard restored state.
    public func restore() {
        if central == nil { createCentral() }
    }

    /// Creates the central without listening, so iOS shows its Bluetooth
    /// prompt during onboarding instead of at the start of the first meeting.
    public func requestPermission() {
        if central == nil { createCentral() }
    }

    /// Only an established subscription is kept when the app leaves the screen.
    public func setDiscoveryAllowed(_ allowed: Bool) {
        guard allowed != allowsDiscovery else { return }
        allowsDiscovery = allowed
        if allowed, device == nil {
            if let central { centralManagerDidUpdateState(central) }
        } else if !allowed, !hasSubscription {
            stop()
            if listening { onStatus?(.waiting) }
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        central.stopScan()
        for peripheral in peripherals {
            if listening, device == nil, peripheral.identifier == preferredID, peripheral.state == .connected {
                device = peripheral
                peripheral.delegate = self
                if hasSubscription {
                    onStatus?(.connected)
                    expectActivity(within: 45)
                } else {
                    releaseDevice()
                }
            } else {
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }
    #endif

    private var hasSubscription: Bool {
        guard let device, device.state == .connected else { return false }
        return device.services?.first { $0.uuid == heartRateService }?.characteristics?.contains {
            $0.uuid == measurement && $0.isNotifying
        } ?? false
    }

    /// Remembers a broadcaster the user picked and connects to it.
    public func use(_ id: UUID) {
        preferredID = id
        preferScan = false
        retryDelay = 5
        stop()
        if let central { centralManagerDidUpdateState(central) }
    }

    public func forgetDevice() {
        preferredID = nil
        stop()
        if let central { centralManagerDidUpdateState(central) }
    }

    private func stop() {
        retry?.cancel()
        retry = nil
        central?.stopScan()
        releaseDevice()
    }

    private func releaseDevice() {
        watchdog?.cancel()
        watchdog = nil
        guard let current = device else { return }
        device = nil
        current.delegate = nil
        central?.cancelPeripheralConnection(current)
    }

    private func startScan() {
        guard listening, allowsDiscovery, let central, central.state == .poweredOn else { return }
        if !preferScan, let known = knownPeripheral(central) {
            preferScan = true
            connect(known, using: central)
            return
        }
        preferScan = false
        scan.begin(at: Date())
        onScan?(scan)
        onStatus?(.searching)
        central.scanForPeripherals(withServices: [heartRateService])
    }

    /// The paired strap by its saved identifier, or a strap the system already
    /// has connected for the heart rate service. Either skips a scan.
    private func knownPeripheral(_ central: CBCentralManager) -> CBPeripheral? {
        if let preferredID, let known = central.retrievePeripherals(withIdentifiers: [preferredID]).first {
            return known
        }
        return central.retrieveConnectedPeripherals(withServices: [heartRateService]).first { peripheral in
            StrapMatch.accepts(
                id: peripheral.identifier, names: [peripheral.name].compactMap { $0 }, preferredID: preferredID
            )
        }
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        device = peripheral
        peripheral.delegate = self
        onStatus?(.connecting)
        central.connect(peripheral)
        expectActivity(within: 20)
    }

    private func scheduleRetry() {
        releaseDevice()
        guard listening, central?.state == .poweredOn else { return }
        guard allowsDiscovery else { onStatus?(.waiting); return }
        retry?.cancel()
        onStatus?(.reconnecting)
        let work = DispatchWorkItem { [weak self] in self?.startScan() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 60)
    }

    private func expectActivity(within seconds: TimeInterval) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleRetry() }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onPermission?(Self.permission)
        if central.state == .poweredOn, listening, hasSubscription { return }
        stop()
        guard listening else { return }
        switch central.state {
        case .poweredOn:
            if allowsDiscovery { startScan() } else { onStatus?(.waiting) }
        case .poweredOff: onStatus?(.poweredOff)
        case .unauthorized: onStatus?(.unauthorized)
        case .unsupported: onStatus?(.unsupported)
        default: onStatus?(.waiting)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard listening, allowsDiscovery, central.state == .poweredOn, device == nil, central.isScanning else { return }
        let advertisement = Advertisement(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            peripheralName: peripheral.name,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        )
        // The scan is filtered on the Heart Rate Service, so every discovery offers it.
        let accepted = StrapMatch.accepts(
            id: peripheral.identifier, advertisement: advertisement, preferredID: preferredID, viaHeartRateFilter: true
        )
        if scan.record(id: peripheral.identifier, advertisement: advertisement, accepted: accepted) {
            onScan?(scan)
            logDiscovery(advertisement, accepted: accepted)
        }
        guard accepted else { return }

        central.stopScan()
        connect(peripheral, using: central)
    }

    private func logDiscovery(_ advertisement: Advertisement, accepted: Bool) {
        let name = advertisement.displayName
        let company = advertisement.companyHex ?? "none"
        let data = advertisement.manufacturerPrefix ?? "none"
        let services = advertisement.serviceUUIDs.joined(separator: ",")
        if accepted {
            log.notice("Accepted heart rate broadcaster name=\(name, privacy: .public) company=\(company, privacy: .public) data=\(data, privacy: .private) services=\(services, privacy: .private)")
        } else {
            log.notice("Ignored heart rate broadcaster name=\(name, privacy: .public) company=\(company, privacy: .public) data=\(data, privacy: .private) services=\(services, privacy: .private)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard device === peripheral else { return }
        guard listening else { stop(); return }
        peripheral.discoverServices([heartRateService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if device === peripheral { scheduleRetry() }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if device === peripheral { scheduleRetry() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard device === peripheral else { return }
        guard listening else { stop(); return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == heartRateService }) else {
            scheduleRetry()
            return
        }
        peripheral.discoverCharacteristics([measurement], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device === peripheral, service.uuid == heartRateService else { return }
        guard listening else { stop(); return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == measurement }),
              characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            scheduleRetry()
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard device === peripheral, characteristic.uuid == measurement else { return }
        guard listening else { stop(); return }
        guard error == nil, characteristic.isNotifying else {
            scheduleRetry()
            return
        }
        preferScan = false
        onStatus?(.connected)
        expectActivity(within: 45)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard device === peripheral, characteristic.uuid == measurement else { return }
        guard listening else { stop(); return }
        guard characteristic.isNotifying,
              error == nil, let data = characteristic.value, let bpm = HeartRateMeasurement.bpm(from: data),
              (25...250).contains(bpm) else { return }
        if preferredID == nil {
            preferredID = peripheral.identifier
            onPaired?(peripheral.identifier)
        }
        retryDelay = 5
        expectActivity(within: 45)
        onReading?(bpm, Date())
    }
}
#endif
