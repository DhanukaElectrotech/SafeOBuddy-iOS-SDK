//
//  SafeobuddyV7.swift
//  SafeOBuddyV7
//
//  Facade mirroring the Android SDK's `SafeLock.openV7Lock` / `closeV7Lock` /
//  `actionV7Lock` — the V7 (BLE-direct) lock path, as opposed to the older
//  TTLock-cloud path exposed by the `Safeobuddy` class in SafeOBuddy.framework.
//
//  Status codes and messages are kept byte-identical to
//  `SafeLock.onLockAction(code, message, type)` so an app can share result
//  handling between the two platforms.
//

import Foundation

public enum SafeobuddyV7 {

    // MARK: - Result

    /// Mirrors the Android `onSafeLockAction(code, message, type)` callback.
    public struct LockActionResult {
        /// `"106"` success, `"102"` open failed, `"100"` lock failed / invalid device.
        public let code: String
        public let message: String
        /// `"open lock"` or `"close lock"`.
        public let type: String

        public var isSuccess: Bool { code == "106" }
    }

    /// The Android `actionType` constants for the V7 path.
    public enum Action: Int {
        case close = 70
        case open  = 71

        var isLock: Bool { self == .close }
        var type: String { isLock ? "close lock" : "open lock" }
    }

    // MARK: - Shared manager

    /// The manager backing the static API. Replace it before the first call if
    /// you need custom timeouts.
    public static var manager = BleLockManager()

    /// `true` while the V7 path is holding the Bluetooth radio. Check this
    /// before starting a legacy `Safeobuddy.openLock(...)` if both paths can be
    /// triggered in the same screen — they use independent central managers but
    /// share one radio.
    public static var isBusy: Bool { manager.isBusy }

    /// Releases the V7 central manager and hands the radio back to the legacy
    /// SDK. Call it when leaving a V7 screen if the app also drives TTLock locks.
    public static func shutdown() {
        manager.shutdown()
    }

    /// Called after every completed action, so the host app can push the
    /// "Opened via APP" / "Failed to close via APP" status to the backend —
    /// the job Android's `updateLockStatus(mMap, …)` does inline. The binary
    /// `SafeOBuddy.framework` does not expose that endpoint, so it is a hook here.
    ///
    /// Receives the MAC and the same status strings Android sends.
    public static var onLockStatusUpdate: ((_ macId: String, _ status: String) -> Void)?

    // MARK: - Public API

    /// Opens a V7 lock over BLE. Counterpart of `SafeLock.openV7Lock(_:deviceCode:)`.
    ///
    /// - Parameters:
    ///   - macId: The lock MAC from the backend device info (`MACID`).
    ///   - onStatus: Optional progress messages ("Connecting…", "Sending command…").
    ///   - completion: Called once, on the main queue.
    public static func openLock(macId: String,
                                onStatus: ((String) -> Void)? = nil,
                                completion: @escaping (LockActionResult) -> Void) {
        perform(.open, macId: macId, onStatus: onStatus, completion: completion)
    }

    /// Closes a V7 lock over BLE. Counterpart of `SafeLock.closeV7Lock(_:)`.
    public static func closeLock(macId: String,
                                 onStatus: ((String) -> Void)? = nil,
                                 completion: @escaping (LockActionResult) -> Void) {
        perform(.close, macId: macId, onStatus: onStatus, completion: completion)
    }

    // MARK: - Implementation (port of `actionV7Lock`)

    private static func perform(_ action: Action,
                                macId: String,
                                onStatus: ((String) -> Void)?,
                                completion: @escaping (LockActionResult) -> Void) {
        let isLock = action.isLock
        let type = action.type

        // Android: `if (!CommonMethods.isValidString(macID))` -> "100 Invalid device info"
        guard PacketBuilder.normalizedMacBytes(macId) != nil else {
            deliver(LockActionResult(code: "100", message: "Invalid device info", type: type),
                    completion)
            return
        }

        manager.openLock(macAddress: macId, isLock: isLock, onStatus: onStatus) { result in
            switch result {
            case .success:
                onLockStatusUpdate?(macId, isLock ? "Closed via APP" : "Opened via APP")
                deliver(LockActionResult(
                    code: "106",
                    message: isLock ? "Device is locked successfully." : "Lock opened successfully.",
                    type: type
                ), completion)

            case .failure:
                onLockStatusUpdate?(macId, isLock ? "Failed to close via APP" : "Failed to open via APP")
                deliver(LockActionResult(
                    code: isLock ? "100" : "102",
                    message: isLock ? "Failed to lock the device." : "failed to open the lock.",
                    type: type
                ), completion)
            }
        }
    }

    private static func deliver(_ result: LockActionResult,
                                _ completion: @escaping (LockActionResult) -> Void) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}
