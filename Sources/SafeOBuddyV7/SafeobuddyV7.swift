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
        /// The MAC the action was performed against, once resolved.
        public let macId: String
        /// The 7 bytes written to the lock, as spaced hex — e.g.
        /// `"e8 94 9a 62 32 dc 55"`. Empty when the action failed before a
        /// packet could be built. Useful for verifying against Android logs.
        public let packetHex: String

        public var isSuccess: Bool { code == "106" }

        init(code: String, message: String, type: String,
             macId: String = "", packetHex: String = "") {
            self.code = code
            self.message = message
            self.type = type
            self.macId = macId
            self.packetHex = packetHex
        }
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

    // MARK: - Step 1: Login

    /// Logs in and stores the session, so no separate `configure` call is needed.
    /// Counterpart of the Android SDK's `mSafeLock.authUser(...)`.
    ///
    /// On success, `uid` and `token` from the login response are captured and
    /// applied automatically — every later call is then authorised.
    ///
    /// ```swift
    /// SafeobuddyV7.login(username: "USERNAME", password: "PASSWORD") { result in
    ///     switch result {
    ///     case .success(let session): print("uid:", session.userId)
    ///     case .failure(let error):   print("login failed:", error.localizedDescription)
    ///     }
    /// }
    /// ```
    public static func login(username: String,
                             password: String,
                             completion: @escaping (Result<SafeobuddySession, AuthError>) -> Void) {
        AuthService.login(username: username, password: password) { result in
            if Thread.isMainThread { completion(result) }
            else { DispatchQueue.main.async { completion(result) } }
        }
    }

    /// The session captured by the most recent successful ``login(username:password:completion:)``.
    public static var session: SafeobuddySession? { AuthService.session }

    /// Clears the stored session.
    public static func logout() { AuthService.logout() }

    // MARK: - Configuration (only if you already hold the session)

    /// Supplies the session the lock-details lookup needs.
    ///
    /// Not required when ``login(username:password:completion:)`` is used — that
    /// captures and applies these values itself.
    ///
    /// Call once after a successful login, before `manualLockAction`.
    ///
    /// - Parameters:
    ///   - contactId: the `uid` from the login response.
    ///   - accessToken: the `token` from the login response.
    ///
    /// Android reads both from `UserSessions` inside the SDK, so its client
    /// never supplies them. `SafeOBuddy.framework` keeps the same values but
    /// does not expose them, so they must be handed in here until the V7
    /// methods can be moved inside the framework itself.
    public static func configure(contactId: String, accessToken: String) {
        LockInfoService.contactId = contactId
        LockInfoService.accessToken = accessToken
    }

    /// `true` once ``configure(contactId:accessToken:)`` has been called with
    /// non-empty values.
    public static var isConfigured: Bool { LockInfoService.isConfigured }

    // MARK: - Public API (lock id — the Android-equivalent entry point)

    /// Opens or closes a V7 lock from its **BT lock id**, resolving the MAC
    /// internally. Direct counterpart of the Android SDK's
    /// `mSafeLock.manualLockAction("Your BT Lock Id", 71)`.
    ///
    /// The SDK performs the `getlockmacdetails` lookup itself, reads the
    /// `LockCode` field (the V7 MAC), and then drives the BLE write — so the
    /// host app never handles a MAC address.
    ///
    /// - Parameters:
    ///   - lockId: **the `DeviceCode` from `Safeobuddy.getDeviceList`.** Android
    ///     calls the same value "BT Lock Id" and "Device Code" interchangeably.
    ///   - type: `71` to open, `70` to close — the same constants Android uses.
    ///   - onStatus: optional progress messages.
    ///   - completion: called once, on the main queue.
    public static func manualLockAction(lockId: String,
                                        type: Int,
                                        onStatus: ((String) -> Void)? = nil,
                                        completion: @escaping (LockActionResult) -> Void) {
        guard let action = Action(rawValue: type) else {
            deliver(LockActionResult(code: "100",
                                     message: "Invalid action type \(type). Use 71 to open or 70 to close.",
                                     type: "open lock"),
                    completion)
            return
        }
        manualLockAction(lockId: lockId, action: action, onStatus: onStatus, completion: completion)
    }

    /// Type-safe form of ``manualLockAction(lockId:type:onStatus:completion:)``.
    public static func manualLockAction(lockId: String,
                                        action: Action,
                                        onStatus: ((String) -> Void)? = nil,
                                        completion: @escaping (LockActionResult) -> Void) {
        let type = action.type

        // Tokens are short-lived, so renew before the lookup if the current one
        // has expired and credentials from `login` are available.
        AuthService.ensureValidSession { ready in
            guard ready else {
                deliver(LockActionResult(code: "100",
                                         message: AuthError.rejected("Session expired — log in again").localizedDescription,
                                         type: type),
                        completion)
                return
            }

            onStatus?("Fetching lock details…")
            LockInfoService.fetchLockInfo(lockId: lockId) { result in
                switch result {
                case .success(let info):
                    // Android: for V7 actions `MACID = LockCode` (SafeLock.java:223-253).
                    perform(action, macId: info.v7MacAddress, onStatus: onStatus, completion: completion)

                case .failure(let error):
                    // Mirrors Android's `validateDevice` returning null.
                    deliver(LockActionResult(code: "100",
                                             message: error.localizedDescription,
                                             type: type),
                            completion)
                }
            }
        }
    }

    // MARK: - Public API (MAC known)

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
        guard let packet = PacketBuilder.buildLockPacket(macAddress: macId, isLock: isLock) else {
            deliver(LockActionResult(code: "100", message: "Invalid device info", type: type),
                    completion)
            return
        }
        let packetHex = PacketBuilder.bytesToHex(packet)
        onStatus?("Command packet: \(packetHex)")

        manager.openLock(macAddress: macId, isLock: isLock, onStatus: onStatus) { result in
            switch result {
            case .success:
                onLockStatusUpdate?(macId, isLock ? "Closed via APP" : "Opened via APP")
                deliver(LockActionResult(
                    code: "106",
                    message: isLock ? "Device is locked successfully." : "Lock opened successfully.",
                    type: type, macId: macId, packetHex: packetHex
                ), completion)

            case .failure:
                onLockStatusUpdate?(macId, isLock ? "Failed to close via APP" : "Failed to open via APP")
                deliver(LockActionResult(
                    code: isLock ? "100" : "102",
                    message: isLock ? "Failed to lock the device." : "failed to open the lock.",
                    type: type, macId: macId, packetHex: packetHex
                ), completion)
            }
        }
    }

    // MARK: - Packet inspection

    /// Returns the exact bytes that ``manualLockAction(lockId:type:onStatus:completion:)``
    /// will write to the lock, without connecting to anything.
    ///
    /// Useful for verifying against the Android SDK's output, and for logging.
    ///
    /// - Returns: spaced hex, e.g. `"e8 94 9a 62 32 dc 55"`, or `nil` if the MAC
    ///   is not valid.
    public static func commandPacket(macId: String, type: Int) -> String? {
        guard let action = Action(rawValue: type),
              let packet = PacketBuilder.buildLockPacket(macAddress: macId, isLock: action.isLock)
        else { return nil }
        return PacketBuilder.bytesToHex(packet)
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
