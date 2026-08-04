//
//  AuthService.swift
//  SafeOBuddyV7
//
//  Logs in and captures the two values every later call needs: `uid` (sent as
//  `contactid`) and `token`.
//
//  Port of the Android SDK's `SafeLock.authUser` result handling:
//
//      UserSessions.saveAccessToken(ctx, mLoginBean.getLoginvalidation().get(0).getToken());
//      UserSessions.saveUserInfo(ctx,   mLoginBean.getLoginvalidation().get(0));   // holds uid
//
//  Android posts an AES-encrypted payload to `Safeobuddy.aspx?method=apss_Web`.
//  That encryption lives in a closed dependency, so this uses the plain
//  `LoginValidation1` endpoint instead — same host, same response shape, plain
//  query parameters and no encryption.
//

import Foundation

public struct SafeobuddySession {
    /// Sent as `contactid` on later calls. From `loginvalidation[0].uid`.
    public let userId: String
    /// Sent as `token` on later calls. From `loginvalidation[0].token`.
    public let accessToken: String
    /// `returnmessage` — `"Successful"` on a good login.
    public let message: String
    /// Display name from `welcomename`, when present.
    public let welcomeName: String
    /// Parsed from `Expirydate`. **Tokens are short-lived** — the server has been
    /// observed issuing tokens that expire the same day.
    public let expiryDate: Date?
    /// The raw `Expirydate` string, for logging.
    public let expiryRaw: String

    /// `true` once the token's expiry has passed. A session with no parseable
    /// expiry is never treated as expired.
    public var isExpired: Bool {
        guard let expiryDate = expiryDate else { return false }
        return expiryDate <= Date()
    }
}

public enum AuthError: Error, LocalizedError {
    case missingCredentials
    case network(Error)
    case badResponse
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Username and password are required"
        case .network(let e):     return e.localizedDescription
        case .badResponse:        return "Unexpected response from the login service"
        case .rejected(let m):    return m.isEmpty ? "Invalid login credentials" : m
        }
    }
}

public enum AuthService {

    /// Same host the rest of the SDK uses.
    public static var baseURL = URL(string: "https://vehicletrack.membocool.com/ConService.aspx")!
    /// `version` query parameter, as sent by the framework. The endpoint accepts
    /// the request with or without it.
    public static var appVersion = "3.7"
    public static var timeout: TimeInterval = 20

    /// Prints the exact request URL and the raw response body to the console.
    ///
    /// Turn this on when a login is rejected but the same credentials succeed in
    /// curl or Postman — it shows precisely what the app sent, including any
    /// stray whitespace or capitalisation introduced by a text field.
    ///
    /// Leave it off in release builds: the request URL contains the password.
    public static var debugLogging = false

    /// The session captured by the most recent successful login.
    public private(set) static var session: SafeobuddySession?

    /// Credentials retained from the last ``login(username:password:completion:)``,
    /// so an expired token can be renewed without the app re-prompting.
    /// Cleared by ``logout()``. Never written to disk.
    private static var credentials: (username: String, password: String)?

    /// Renews the session if the token has expired, then runs `work`.
    ///
    /// Tokens are short-lived, so this is called before every lock-details
    /// lookup. If there is no session and no stored credentials, `work` receives
    /// `false` and the caller reports "not configured".
    static func ensureValidSession(_ work: @escaping (_ ready: Bool) -> Void) {
        if let session = session, !session.isExpired {
            work(true); return
        }
        guard let credentials = credentials else {
            // Either never logged in, or configured manually with a token whose
            // lifetime we cannot see — let the call proceed and surface the
            // server's own error.
            work(LockInfoService.isConfigured); return
        }
        login(username: credentials.username, password: credentials.password) { result in
            switch result {
            case .success: work(true)
            case .failure: work(false)
            }
        }
    }

    /// Logs in and returns the session. On success the values are applied to
    /// ``LockInfoService`` automatically, so no separate `configure` call is needed.
    public static func login(username: String,
                             password: String,
                             completion: @escaping (Result<SafeobuddySession, AuthError>) -> Void) {
        // Trim: text fields commonly deliver a trailing space, which the server
        // rejects with no visible difference in the UI.
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            completion(.failure(.missingCredentials)); return
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            completion(.failure(.badResponse)); return
        }
        components.queryItems = [
            URLQueryItem(name: "method",  value: "LoginValidation1"),
            URLQueryItem(name: "uid",     value: username),
            URLQueryItem(name: "pwd",     value: password),
            URLQueryItem(name: "version", value: appVersion)
        ]
        guard let url = components.url else {
            completion(.failure(.badResponse)); return
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // Do not let a cached response stand in for a fresh login.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        if debugLogging {
            print("[SafeobuddyV7] username: [\(username)]  password: [\(password)]")
            print("[SafeobuddyV7] GET \(url.absoluteString)")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if debugLogging {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("[SafeobuddyV7] HTTP \(status)")
                print("[SafeobuddyV7] body: \(body)")
            }
            if let error = error {
                completion(.failure(.network(error))); return
            }
            guard let data = data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                completion(.failure(.badResponse)); return
            }

            // Android reads `loginvalidation[0]`. Fall back to the root object in
            // case the endpoint returns the fields un-nested.
            let row = (root["loginvalidation"] as? [[String: Any]])?.first ?? root

            let userId = string(row["uid"])
            let token = string(row["token"])

            // A rejected login has no `loginvalidation` array at all — the reason
            // arrives as `message` on the root object, e.g.
            //   {"success":"0","message":"Please Check UserId or Password !!!"}
            // A successful one carries `returnmessage` inside the row. Read both,
            // so the server's own wording always reaches the caller.
            let message = [string(row["returnmessage"]), string(root["message"])]
                .first(where: { !$0.isEmpty }) ?? ""

            // Android treats uid "" or "0" as a failed login.
            guard !userId.isEmpty, userId != "0", !token.isEmpty else {
                completion(.failure(.rejected(message))); return
            }

            let expiryRaw = string(row["Expirydate"])
            let session = SafeobuddySession(userId: userId,
                                            accessToken: token,
                                            message: message,
                                            welcomeName: string(row["welcomename"]),
                                            expiryDate: parseExpiry(expiryRaw),
                                            expiryRaw: expiryRaw)
            self.session = session
            self.credentials = (username, password)
            LockInfoService.contactId = userId
            LockInfoService.accessToken = token

            completion(.success(session))
        }.resume()
    }

    /// Clears the stored session, the retained credentials and the values handed
    /// to ``LockInfoService``.
    public static func logout() {
        session = nil
        credentials = nil
        LockInfoService.contactId = nil
        LockInfoService.accessToken = nil
    }

    /// Parses the server's `Expirydate`, e.g. `"Aug  4 2026  1:52PM"`.
    ///
    /// The field arrives in SQL Server's default format, which pads single-digit
    /// days and the time with extra spaces — collapse whitespace before parsing.
    static func parseExpiry(_ raw: String) -> Date? {
        let normalized = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d yyyy h:mma", "MMM d yyyy H:mm", "MMM d yyyy h:mm a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let s as String:   return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}
