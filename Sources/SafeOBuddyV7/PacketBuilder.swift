//
//  PacketBuilder.swift
//  SafeOBuddyV7
//
//  Port of the Android SDK's `newV7lock/PacketBuilder.kt`
//  (itself a port of the Flutter PacketBuilder).
//
//  Takes a MAC like "5C:53:10:4F:37:AE", reverses the byte order,
//  keeps the first 6 bytes, then appends the command byte:
//    0x4C = LOCK, 0x55 = UNLOCK (open)
//  Final packet is 7 bytes.
//

import Foundation

public enum PacketBuilder {

    /// LOCK command byte (`0x4C`, "4c" in the Android SDK).
    public static let cmdLock: UInt8 = 0x4C

    /// UNLOCK / "open" command byte (`0x55`, "55" in the Android SDK).
    public static let cmdUnlock: UInt8 = 0x55

    /// Builds the 7-byte V7 control packet for a lock.
    ///
    /// - Parameters:
    ///   - macAddress: The lock's MAC, with or without `:` / `-` separators.
    ///   - isLock: `true` to send the LOCK command, `false` to open.
    /// - Returns: The 7-byte payload, or `nil` if `macAddress` is not valid hex
    ///   of at least 6 bytes.
    public static func buildLockPacket(macAddress: String, isLock: Bool) -> Data? {
        guard let macBytes = normalizedMacBytes(macAddress) else { return nil }

        // 5c:53:10:4f:37:ae -> AE 37 4F 10 53 5C, then take the first 6 bytes.
        let macPart = Array(macBytes.reversed().prefix(6))

        return Data(macPart + [isLock ? cmdLock : cmdUnlock])
    }

    /// Strips separators and decodes a MAC string into its 6 raw bytes,
    /// in the order they appear in the string (i.e. *not* reversed).
    ///
    /// Returns `nil` unless the result is at least 6 bytes.
    public static func normalizedMacBytes(_ macAddress: String) -> [UInt8]? {
        let cleanMac = macAddress
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard let bytes = hexToBytes(cleanMac), bytes.count >= 6 else { return nil }
        return bytes
    }

    /// Decodes a hex string into bytes. Tolerates `0x` prefixes, spaces and dashes.
    /// Returns `nil` for odd-length or non-hex input.
    public static func hexToBytes(_ hex: String) -> [UInt8]? {
        let clean = hex
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)

        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Space-separated lowercase hex, matching the Android `bytesToHex` output.
    public static func bytesToHex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
