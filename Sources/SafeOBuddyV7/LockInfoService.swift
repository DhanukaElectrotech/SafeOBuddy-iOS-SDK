//
//  LockInfoService.swift
//  SafeOBuddyV7
//
//  Resolves a BT lock id to the lock's Bluetooth MAC, so the host app never has
//  to know the MAC — matching how the Android SDK works, where the client only
//  ever passes a lock id to `manualLockAction(lockId, 71 / 70)` and the SDK
//  fetches the MAC itself.
//
//  Port of `ApiCall.getDeviceInfo` + `DeviceInfoBean`:
//
//      GET ConService.aspx?method=getlockmacdetails
//              &lockid=<BT lock id>&contactid=<user id>&token=<access token>
//
//  Unlike the login and records calls, this endpoint is a plain GET returning
//  plain JSON — the Android SDK parses it straight through Gson with no AES
//  layer, so no encryption is replicated here.
//

import Foundation

public enum LockInfoError: Error, LocalizedError {
    case notConfigured
    case invalidLockId
    case network(Error)
    case badResponse
    case noLockFound

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SafeobuddyV7 is not configured. Call SafeobuddyV7.configure(contactId:token:) after login."
        case .invalidLockId:  return "Invalid lock id"
        case .network(let e): return e.localizedDescription
        case .badResponse:    return "Unexpected response from the lock details service"
        case .noLockFound:    return "No lock found for this id"
        }
    }
}

/// One row of the `returnds` array returned by `getlockmacdetails`.
public struct LockInfo {
    public let lockId: String
    /// **The Bluetooth MAC for V7 locks.** Android assigns `MACID = LockCode`
    /// for V7 actions (71 / 70) and `MACID = MacId` for standard TTLock
    /// actions — the two fields are used the opposite way round. See
    /// `SafeLock.java:223-253`.
    public let lockCode: String
    /// The MAC used by the standard (TTLock) flow. Not the V7 MAC.
    public let macId: String
    public let lockData: String
    public let vehicleNumber: String

    /// The MAC the V7 BLE path must use.
    public var v7MacAddress: String { lockCode }
}

public enum LockInfoService {

    // MARK: Configuration

    /// Defaults to the same host the Android SDK uses.
    public static var baseURL = URL(string: "https://vehicletrack.membocool.com/ConService.aspx")!

    /// `contactid` — the `uid` from the login response.
    public static var contactId: String?
    /// `token` — the access token from the login response.
    public static var accessToken: String?
    public static var timeout: TimeInterval = 20

    public static var isConfigured: Bool {
        !(contactId ?? "").isEmpty && !(accessToken ?? "").isEmpty
    }

    // MARK: Lookup

    /// Fetches lock details for a device code and returns the first row that
    /// carries a usable `LockCode`.
    ///
    /// - Parameter lockId: **the `DeviceCode` from `getDeviceList`.** Android
    ///   calls this value "BT Lock Id", "Device Code" and `lockid` in different
    ///   places, but they are all the same field — `manualLockAction` assigns
    ///   `deviceCode = lockId` before passing it straight through as `lockid`
    ///   (`SafeLock.java:488-490`).
    ///
    /// The MAC is **not** part of the device list response; it only ever comes
    /// from this endpoint.
    ///
    /// Android applies the same filter for V7 actions: it keeps only rows where
    /// `isValidString(getLockCode())`, then uses that value as the MAC.
    public static func fetchLockInfo(lockId: String,
                                     completion: @escaping (Result<LockInfo, LockInfoError>) -> Void) {
        let trimmed = lockId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(.invalidLockId)); return
        }
        guard let contactId = contactId, let token = accessToken,
              !contactId.isEmpty, !token.isEmpty else {
            completion(.failure(.notConfigured)); return
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            completion(.failure(.badResponse)); return
        }
        components.queryItems = [
            URLQueryItem(name: "method", value: "getlockmacdetails"),
            URLQueryItem(name: "lockid", value: trimmed),
            URLQueryItem(name: "contactid", value: contactId),
            URLQueryItem(name: "token", value: token)
        ]
        guard let url = components.url else {
            completion(.failure(.badResponse)); return
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(.network(error))); return
            }
            guard let data = data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                completion(.failure(.badResponse)); return
            }
            guard let rows = root["returnds"] as? [[String: Any]] else {
                completion(.failure(.badResponse)); return
            }

            let infos = rows.map { row in
                LockInfo(lockId:        string(row["LockId"]),
                         lockCode:      string(row["LockCode"]),
                         macId:         string(row["MacId"]),
                         lockData:      string(row["Lockdata"]),
                         vehicleNumber: string(row["VehicleNumber"]))
            }

            // Android keeps only rows with a non-empty LockCode for V7 actions.
            guard let match = infos.first(where: { !$0.lockCode.isEmpty }) else {
                completion(.failure(.noLockFound)); return
            }
            completion(.success(match))
        }.resume()
    }

    /// The API returns some numeric fields as JSON numbers and some as strings.
    private static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}
