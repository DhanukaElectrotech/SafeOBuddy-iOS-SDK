//
//  BleLockManager.swift
//  SafeOBuddyV7
//
//  CoreBluetooth port of the Android SDK's `newV7lock/BleLockManager.kt`.
//
//  Two responsibilities, same as the Android class:
//    1. scan()             -> report discovered peripherals to the UI
//    2. openLock(mac:)     -> connect, send the OPEN/LOCK packet, then disconnect
//
//  ---------------------------------------------------------------------------
//  IMPORTANT DIFFERENCE FROM ANDROID
//  ---------------------------------------------------------------------------
//  Android connects straight to a MAC via `BluetoothAdapter.getRemoteDevice(mac)`.
//  iOS has no such API: CoreBluetooth never exposes a peripheral's MAC and will
//  only connect to a `CBPeripheral` handed to it by a scan (or restored from a
//  previously seen `UUID`). So this port has to *find* the lock first, by
//  matching the server-supplied MAC against each advertisement packet.
//
//  Once a MAC has been resolved to a peripheral UUID it is cached in
//  `UserDefaults`, so later opens skip the scan entirely.
//
//  The caller is responsible for `NSBluetoothAlwaysUsageDescription` in
//  Info.plist. Unlike Android, iOS needs no location permission for BLE.
//

import CoreBluetooth
import Foundation

// MARK: - Callback

/// Mirrors `BleLockManager.LockCallback` from the Android SDK.
/// All methods are delivered on the main queue.
public protocol LockCallback: AnyObject {
    func onStatus(_ message: String)
    func onSuccess()
    func onError(_ message: String)
}

// MARK: - Manager

public final class BleLockManager: NSObject {

    // MARK: Configuration

    public struct Configuration {
        /// How long to scan for the target MAC before giving up.
        public var scanTimeout: TimeInterval
        /// How long to wait for the GATT connection to come up.
        public var connectTimeout: TimeInterval
        /// How long to wait for service + characteristic discovery.
        public var discoveryTimeout: TimeInterval
        /// Grace period after a write-without-response before tearing the link
        /// down. iOS queues these writes; cancelling immediately can drop the
        /// packet before the radio sends it. Android has no equivalent because
        /// `gatt.disconnect()` flushes first.
        public var writeWithoutResponseGrace: TimeInterval
        /// Whether CoreBluetooth may show the system "Turn On Bluetooth" alert.
        ///
        /// Defaults to `false` on purpose: `SafeOBuddy.framework` runs its own
        /// central manager and already surfaces Bluetooth state through the
        /// legacy flow. Leaving this off guarantees this module never puts a
        /// system alert on screen that the app did not have before.
        public var showPowerAlert: Bool

        public init(scanTimeout: TimeInterval = 15,
                    connectTimeout: TimeInterval = 15,
                    discoveryTimeout: TimeInterval = 10,
                    writeWithoutResponseGrace: TimeInterval = 0.6,
                    showPowerAlert: Bool = false) {
            self.scanTimeout = scanTimeout
            self.connectTimeout = connectTimeout
            self.discoveryTimeout = discoveryTimeout
            self.writeWithoutResponseGrace = writeWithoutResponseGrace
            self.showPowerAlert = showPowerAlert
        }
    }

    // MARK: Internal operation state

    private final class Operation {
        let macAddress: String
        let macBytes: [UInt8]
        let payload: Data
        let isLock: Bool
        let callback: LockCallback

        var peripheral: CBPeripheral?
        var pendingCharacteristicDiscoveries = 0
        var didFinishServiceDiscovery = false
        var writeDispatched = false
        var awaitingAck = false
        var reported = false
        var timeout: DispatchWorkItem?

        init(macAddress: String,
             macBytes: [UInt8],
             payload: Data,
             isLock: Bool,
             callback: LockCallback) {
            self.macAddress = macAddress
            self.macBytes = macBytes
            self.payload = payload
            self.isLock = isLock
            self.callback = callback
        }
    }

    // MARK: Stored properties

    private let queue = DispatchQueue(label: "com.safeobuddy.v7.ble")
    private let configuration: Configuration
    /// Created lazily, and deliberately WITHOUT `CBCentralManagerOptionRestoreIdentifierKey`.
    ///
    /// `SafeOBuddy.framework` already owns a restoring central manager (it
    /// implements `centralManager:willRestoreState:`). Staying out of state
    /// restoration means this manager is never revived in the background and can
    /// never be confused with the legacy one.
    ///
    /// Nothing here is constructed until the first V7 call, so an app that never
    /// touches `SafeOBuddyV7` gets no second central manager at all.
    private var _central: CBCentralManager?
    private var central: CBCentralManager {
        if let existing = _central { return existing }
        let created = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: configuration.showPowerAlert
        ])
        _central = created
        return created
    }

    private var operation: Operation?
    private var scanHandler: ((CBPeripheral, [String: Any], NSNumber) -> Void)?
    private var pendingPowerOnWork: [() -> Void] = []
    /// Strong refs to peripherals we are mid-operation on. CoreBluetooth does
    /// not retain them, and a deallocated `CBPeripheral` silently kills the
    /// connection.
    private var retainedPeripherals = Set<CBPeripheral>()

    private static let cacheKey = "macToPeripheralUUID"

    /// A private `UserDefaults` suite, so nothing this module stores can ever
    /// land in `UserDefaults.standard` alongside the legacy SDK's session data.
    private static let defaults =
        UserDefaults(suiteName: "com.safeobuddy.v7") ?? .standard

    // MARK: Init

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init()
    }

    /// Mirrors `BleLockManager.isBluetoothOn`.
    ///
    /// Reading this powers up `CBCentralManager`, which is what triggers the
    /// system Bluetooth permission prompt — so touch it only when you are ready
    /// to ask the user.
    public var isBluetoothOn: Bool {
        queue.sync { central.state == .poweredOn }
    }

    // MARK: - 1. Scanning

    /// Starts a scan. `onDeviceFound` is called on the main thread per advertisement.
    public func startScan(onDeviceFound: @escaping (CBPeripheral, [String: Any], NSNumber) -> Void) {
        queue.async {
            self.scanHandler = onDeviceFound
            self.whenPoweredOn {
                self.central.stopScan()
                self.central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
            }
        }
    }

    public func stopScan() {
        queue.async {
            self.scanHandler = nil
            // `_central`, not `central`: stopping a scan must never be the thing
            // that brings a second central manager into existence.
            if self.operation == nil, self._central?.state == .poweredOn {
                self._central?.stopScan()
            }
        }
    }

    // MARK: - 2. Open lock (connect -> send command -> disconnect)

    /// The one method the app calls from its "Open" button — the direct
    /// counterpart of the Android `openLock(device, isLock, callback)`.
    ///
    /// Resolves `macAddress` to a peripheral (cache first, then scan), connects,
    /// discovers services, writes the V7 packet to the first writable
    /// characteristic, then disconnects.
    ///
    /// - Parameters:
    ///   - macAddress: MAC reported by the SafeOBuddy backend for this device.
    ///   - isLock: `true` sends the LOCK command instead of OPEN.
    public func openLock(macAddress: String, isLock: Bool = false, callback: LockCallback) {
        guard let macBytes = PacketBuilder.normalizedMacBytes(macAddress),
              let payload = PacketBuilder.buildLockPacket(macAddress: macAddress, isLock: isLock)
        else {
            DispatchQueue.main.async { callback.onError("Invalid MAC address: \(macAddress)") }
            return
        }

        queue.async {
            guard self.operation == nil else {
                DispatchQueue.main.async { callback.onError("Another lock operation is already in progress") }
                return
            }

            let op = Operation(macAddress: macAddress,
                               macBytes: macBytes,
                               payload: payload,
                               isLock: isLock,
                               callback: callback)
            self.operation = op

            self.whenPoweredOn {
                guard self.operation === op else { return }
                self.report(op, status: "Connecting…")
                self.locateAndConnect(op)
            }
        }
    }

    /// Closure-based convenience over ``openLock(macAddress:isLock:callback:)``.
    public func openLock(macAddress: String,
                         isLock: Bool = false,
                         onStatus: ((String) -> Void)? = nil,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        // The shim is retained by the dispatched work and then by the Operation,
        // so it stays alive until it reports a terminal result.
        openLock(macAddress: macAddress,
                 isLock: isLock,
                 callback: ClosureCallback(onStatus: onStatus, completion: completion))
    }

    /// Pre-associates a MAC with a peripheral UUID you already know (e.g. from
    /// your own scan UI), letting the next `openLock` skip discovery.
    public func register(macAddress: String, peripheralIdentifier: UUID) {
        queue.async {
            var cache = Self.loadCache()
            cache[Self.cacheIdentity(macAddress)] = peripheralIdentifier.uuidString
            Self.saveCache(cache)
        }
    }

    /// Forgets every cached MAC -> peripheral association.
    public func clearPeripheralCache() {
        queue.async { Self.saveCache([:]) }
    }

    // MARK: - Coexistence with the legacy (TTLock) flow

    /// `true` while this module holds the Bluetooth radio — i.e. it is scanning,
    /// connecting, or writing.
    ///
    /// `SafeOBuddy.framework` drives its own `CBCentralManager`. Two central
    /// managers in one process are legal and independent, but they share one
    /// radio, so an unfiltered scan here will slow a concurrent legacy connect.
    /// Check this before starting a legacy `Safeobuddy.openLock(...)` if the two
    /// paths can overlap in your app.
    public var isBusy: Bool {
        queue.sync { operation != nil || scanHandler != nil }
    }

    /// Stops any scan, drops any connection this module opened, and releases its
    /// `CBCentralManager` so the radio is left entirely to the legacy SDK.
    ///
    /// Safe to call at any time; a new manager is created on the next V7 call.
    /// It acts only on this module's own central manager and on the
    /// `CBPeripheral` instances that central vended — each `CBCentralManager`
    /// vends its own peripheral objects, so nothing here reaches the legacy
    /// SDK's manager, its peripherals, or its delegates.
    public func shutdown() {
        queue.sync {
            if let op = operation {
                fail(op, "Cancelled")
                if let peripheral = op.peripheral {
                    _central?.cancelPeripheralConnection(peripheral)
                }
                op.timeout?.cancel()
                op.timeout = nil
                operation = nil
            }
            scanHandler = nil
            pendingPowerOnWork.removeAll()
            retainedPeripherals.forEach { $0.delegate = nil }
            retainedPeripherals.removeAll()

            if let central = _central {
                if central.state == .poweredOn { central.stopScan() }
                central.delegate = nil
            }
            _central = nil
        }
    }

    deinit {
        // Never touch `central` here — that would construct one just to destroy it.
        if let central = _central {
            if central.state == .poweredOn { central.stopScan() }
            central.delegate = nil
        }
        retainedPeripherals.forEach { $0.delegate = nil }
    }

    // MARK: - Connection flow

    private func locateAndConnect(_ op: Operation) {
        // Fast path: we have seen this lock before.
        if let cached = Self.loadCache()[Self.cacheIdentity(op.macAddress)],
           let uuid = UUID(uuidString: cached),
           let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(op, to: peripheral)
            return
        }

        // Slow path: scan and match the MAC out of the advertisement.
        report(op, status: "Scanning for lock…")
        arm(op, timeout: configuration.scanTimeout,
            failure: "Lock \(op.macAddress) not found in range")
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func connect(_ op: Operation, to peripheral: CBPeripheral) {
        if scanHandler == nil { central.stopScan() }

        op.peripheral = peripheral
        retainedPeripherals.insert(peripheral)
        peripheral.delegate = self

        arm(op, timeout: configuration.connectTimeout,
            failure: "Timed out connecting to \(op.macAddress)")
        central.connect(peripheral, options: nil)
    }

    /// Android's `findWritableCharacteristic` — first characteristic, in
    /// discovery order, that supports write or write-without-response.
    private func findWritableCharacteristic(_ peripheral: CBPeripheral) -> CBCharacteristic? {
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                let props = characteristic.properties
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    return characteristic
                }
            }
        }
        return nil
    }

    private func sendPacket(_ op: Operation, on peripheral: CBPeripheral) {
        guard let characteristic = findWritableCharacteristic(peripheral) else {
            fail(op, "No writable characteristic found")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        report(op, status: "Sending command…")

        let supportsNoResponse = characteristic.properties.contains(.writeWithoutResponse)

        if supportsNoResponse {
            // Prefer write-WITHOUT-response, exactly as Android does: it avoids
            // the ACK wait that makes these locks report GATT status 133.
            guard peripheral.canSendWriteWithoutResponse else {
                // Radio is not ready — `peripheralIsReady` will call us back.
                arm(op, timeout: configuration.discoveryTimeout,
                    failure: "Could not send command")
                return
            }
            peripheral.writeValue(op.payload, for: characteristic, type: .withoutResponse)
            op.writeDispatched = true

            // Fire-and-forget: for no-response writes the command is "delivered"
            // once the stack accepts it — there is no ACK to wait for.
            succeed(op)
            let grace = configuration.writeWithoutResponseGrace
            queue.asyncAfter(deadline: .now() + grace) { [weak self] in
                self?.central.cancelPeripheralConnection(peripheral)
            }
        } else {
            peripheral.writeValue(op.payload, for: characteristic, type: .withResponse)
            op.writeDispatched = true
            op.awaitingAck = true
            arm(op, timeout: configuration.discoveryTimeout,
                failure: "Timed out waiting for write acknowledgement")
        }
    }

    // MARK: - Reporting (exactly once, on main)

    private func report(_ op: Operation, status: String) {
        guard !op.reported else { return }
        let callback = op.callback
        DispatchQueue.main.async { callback.onStatus(status) }
    }

    private func succeed(_ op: Operation) {
        guard !op.reported else { return }
        op.reported = true
        op.timeout?.cancel()
        op.timeout = nil
        let callback = op.callback
        DispatchQueue.main.async { callback.onSuccess() }
    }

    private func fail(_ op: Operation, _ message: String) {
        guard !op.reported else { return }
        op.reported = true
        op.timeout?.cancel()
        op.timeout = nil
        let callback = op.callback
        DispatchQueue.main.async { callback.onError(message) }
    }

    /// Ends the operation and releases every resource tied to it.
    private func finish(_ op: Operation) {
        guard operation === op else { return }
        op.timeout?.cancel()
        op.timeout = nil
        if let peripheral = op.peripheral {
            retainedPeripherals.remove(peripheral)
            peripheral.delegate = nil
        }
        operation = nil
        if scanHandler == nil, _central?.state == .poweredOn {
            _central?.stopScan()
        }
    }

    // MARK: - Helpers

    private func arm(_ op: Operation, timeout: TimeInterval, failure: String) {
        op.timeout?.cancel()
        // `op` is held weakly so the work item does not form a cycle with
        // `op.timeout`; the live operation is kept alive by `self.operation`.
        let work = DispatchWorkItem { [weak self, weak op] in
            guard let self = self, let op = op, self.operation === op else { return }
            self.fail(op, failure)
            if let peripheral = op.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.finish(op)
        }
        op.timeout = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func whenPoweredOn(_ work: @escaping () -> Void) {
        switch central.state {
        case .poweredOn:
            work()
        case .unknown, .resetting:
            pendingPowerOnWork.append(work)
        default:
            failEverythingPending(with: Self.message(for: central.state))
        }
    }

    private func failEverythingPending(with message: String) {
        pendingPowerOnWork.removeAll()
        if let op = operation {
            fail(op, message)
            finish(op)
        }
    }

    private static func message(for state: CBManagerState) -> String {
        switch state {
        case .poweredOff:   return "Bluetooth is turned off"
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported:  return "Bluetooth Low Energy is not supported on this device"
        case .resetting:    return "Bluetooth is resetting"
        case .unknown:      return "Bluetooth state is unknown"
        @unknown default:   return "Bluetooth is unavailable"
        }
    }

    // MARK: MAC matching

    /// Tries to prove that `peripheral` is the lock whose MAC is `op.macBytes`.
    ///
    /// The MAC is looked for in the manufacturer data and service data (forward
    /// and byte-reversed — V7 modules advertise it both ways depending on
    /// firmware), then in the advertised name.
    private func matches(_ op: Operation,
                         peripheral: CBPeripheral,
                         advertisementData: [String: Any]) -> Bool {
        let mac = op.macBytes
        let reversed = Array(mac.reversed())

        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](data)
            if bytes.contains(subsequence: mac) || bytes.contains(subsequence: reversed) { return true }
        }

        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for data in serviceData.values {
                let bytes = [UInt8](data)
                if bytes.contains(subsequence: mac) || bytes.contains(subsequence: reversed) { return true }
            }
        }

        let macHex = mac.map { String(format: "%02X", $0) }.joined()
        let reversedHex = reversed.map { String(format: "%02X", $0) }.joined()
        let names = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name]

        for case let name? in names {
            let hexOnly = String(name.uppercased().filter { $0.isHexDigit })
            guard hexOnly.count >= 6 else { continue }
            if hexOnly.contains(macHex) || hexOnly.contains(reversedHex) { return true }
            // Some modules advertise only the trailing 3 bytes of the MAC.
            if macHex.hasSuffix(hexOnly) || reversedHex.hasSuffix(hexOnly) { return true }
        }

        return false
    }

    // MARK: Peripheral cache

    private static func cacheIdentity(_ mac: String) -> String {
        mac.uppercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func loadCache() -> [String: String] {
        defaults.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
    }

    private static func saveCache(_ cache: [String: String]) {
        defaults.set(cache, forKey: cacheKey)
    }
}

// MARK: - CBCentralManagerDelegate

extension BleLockManager: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let pending = pendingPowerOnWork
            pendingPowerOnWork.removeAll()
            pending.forEach { $0() }
            if scanHandler != nil {
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
            }
        case .unknown, .resetting:
            break
        default:
            failEverythingPending(with: Self.message(for: central.state))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        if let handler = scanHandler {
            DispatchQueue.main.async { handler(peripheral, advertisementData, RSSI) }
        }

        guard let op = operation, op.peripheral == nil, !op.reported else { return }
        guard matches(op, peripheral: peripheral, advertisementData: advertisementData) else { return }

        var cache = Self.loadCache()
        cache[Self.cacheIdentity(op.macAddress)] = peripheral.identifier.uuidString
        Self.saveCache(cache)

        report(op, status: "Lock found, connecting…")
        connect(op, to: peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let op = operation, op.peripheral === peripheral else { return }
        report(op, status: "Connected, discovering services…")
        arm(op, timeout: configuration.discoveryTimeout,
            failure: "Timed out discovering services")
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        guard let op = operation, op.peripheral === peripheral else { return }
        fail(op, error?.localizedDescription ?? "Failed to connect to the lock")
        finish(op)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard let op = operation, op.peripheral === peripheral else {
            retainedPeripherals.remove(peripheral)
            return
        }

        if !op.reported {
            if op.writeDispatched {
                // The Android port treats GATT status 133 as a false negative:
                // the lock acted on the command and dropped the link before
                // ACKing. The iOS equivalent is exactly this — a disconnect
                // arriving after the write went out but before `didWriteValueFor`.
                succeed(op)
            } else {
                fail(op, error?.localizedDescription ?? "Disconnected before the command was sent")
            }
        }

        finish(op)
    }
}

// MARK: - CBPeripheralDelegate

extension BleLockManager: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let op = operation, op.peripheral === peripheral else { return }

        if let error = error {
            fail(op, "Service discovery failed: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            fail(op, "No writable characteristic found")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        op.pendingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let op = operation, op.peripheral === peripheral else { return }

        op.pendingCharacteristicDiscoveries -= 1
        guard op.pendingCharacteristicDiscoveries <= 0, !op.didFinishServiceDiscovery else { return }

        op.didFinishServiceDiscovery = true
        sendPacket(op, on: peripheral)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let op = operation,
              op.peripheral === peripheral,
              op.didFinishServiceDiscovery,
              !op.writeDispatched,
              !op.reported
        else { return }

        sendPacket(op, on: peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Only fires for write-WITH-response.
        guard let op = operation, op.peripheral === peripheral, op.awaitingAck else { return }
        op.awaitingAck = false

        if let error = error {
            fail(op, "Write failed: \(error.localizedDescription)")
        } else {
            succeed(op)
        }
        central.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - Closure shim

private final class ClosureCallback: LockCallback {
    private let onStatusHandler: ((String) -> Void)?
    private let completion: (Result<Void, Error>) -> Void

    init(onStatus: ((String) -> Void)?, completion: @escaping (Result<Void, Error>) -> Void) {
        self.onStatusHandler = onStatus
        self.completion = completion
    }

    func onStatus(_ message: String) { onStatusHandler?(message) }

    func onSuccess() {
        completion(.success(()))
    }

    func onError(_ message: String) {
        completion(.failure(NSError(domain: "com.safeobuddy.v7.ble",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: message])))
    }
}

// MARK: - Byte helpers

private extension Array where Element == UInt8 {
    /// True when `needle` appears contiguously in the receiver.
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) where Array(self[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
