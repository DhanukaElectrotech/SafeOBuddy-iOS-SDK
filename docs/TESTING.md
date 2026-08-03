# Testing Guide — SafeOBuddy iOS SDK

Internal document. Work through the stages in order: each one needs strictly more
than the last, and a failure early on makes the later stages meaningless.

| Stage | Needs | Answers |
|---|---|---|
| 1. Type-check | A Mac | Does the V7 code compile at all? |
| 2. Packet test | A Mac | Is the BLE packet byte-correct? |
| 3. Status code | Mac + iPhone + login | Is the success code `600` or `106`? |
| 4. Advertisement dump | + a powered V7 lock | Can iOS find the lock by MAC? |
| 5. Open / close | + the same lock | Does the lock actually operate? |
| 6. Coexistence | + a TTLock device | Does the new code disturb the old flow? |

---

## Stage 1 — Type-check (2 minutes, no Xcode project needed)

The V7 sources have never been compiled. Do this before anything else.

```bash
cd SafeOBuddy-iOS-SDK

xcrun swiftc \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -target arm64-apple-ios13.0 \
  -typecheck \
  Sources/SafeOBuddyV7/*.swift
```

No output means it compiles. `-typecheck` skips code generation, so it takes a few
seconds and needs no project, scheme or signing.

---

## Stage 2 — Packet correctness (no hardware)

`PacketBuilder` only needs Foundation, so it runs on the Mac itself:

```bash
cat Sources/SafeOBuddyV7/PacketBuilder.swift > /tmp/pt.swift
cat >> /tmp/pt.swift <<'EOF'

let mac = "5C:53:10:4F:37:AE"
let open  = PacketBuilder.buildLockPacket(macAddress: mac, isLock: false)!
let lock  = PacketBuilder.buildLockPacket(macAddress: mac, isLock: true)!

print("open:", PacketBuilder.bytesToHex(open))
print("lock:", PacketBuilder.bytesToHex(lock))

assert(PacketBuilder.bytesToHex(open) == "ae 37 4f 10 53 5c 55", "OPEN packet wrong")
assert(PacketBuilder.bytesToHex(lock) == "ae 37 4f 10 53 5c 4c", "LOCK packet wrong")
print("PASS — packets match the Android SDK")
EOF

swift /tmp/pt.swift
```

Expected:

```
open: ae 37 4f 10 53 5c 55
lock: ae 37 4f 10 53 5c 4c
PASS — packets match the Android SDK
```

These are the exact bytes the Android SDK sends for the same MAC.

---

## Stage 3 — Confirm the success status code

**The client document currently states `"600"`, taken from the SDK README. This was
never confirmed against a live response.** Android uses `106`. Settle it before the
document goes out.

In a test app on a **physical iPhone**:

```swift
import SafeOBuddy

Safeobuddy.intializeSafeobuddy { message in
    print("[INIT]", message)

    Safeobuddy.authUser(email: "REAL_USERNAME", password: "REAL_PASSWORD") { message, statusCode in
        print("[AUTH] statusCode =", statusCode, "| message =", message)

        Safeobuddy.getDeviceList { response, message, statusCode in
            print("[LIST] statusCode =", statusCode, "| count =", response.count)
            for device in response {
                print("   deviceCode:", device["deviceCode"] ?? "-",
                      "MACID:", device["MACID"] ?? device["macId"] ?? "-")
            }
        }
    }
}
```

Whatever `statusCode` prints on a **successful** auth is the real success code. If it
is not `600`, tell me and I will correct every example in the document.

### Getting the V7 MAC — read this before Stage 4

Stage 4 needs a real MAC, and it does **not** come from the device list.

In the Android SDK the MAC is fetched from a second endpoint that the iOS SDK does
not expose, and the field is **`LockCode`**, not `MacId`:

```
ConService.aspx?method=getlockmacdetails&lockid=<btlockid>&contactid=<uid>&token=<accessToken>
```

> **The two fields are swapped by lock type.** For V7 locks the MAC is `LockCode`;
> for standard TTLock devices it is `MacId` (`SafeLock.java:223-253`). Passing `MacId`
> to a V7 lock builds the wrong packet, and because the write is unacknowledged the
> call still reports `106`. A silent no-op is the symptom.

First find out what the iOS device list actually returns:

```swift
Safeobuddy.getDeviceList { response, message, statusCode in
    for device in response {
        print(device.keys.sorted())
        print("btlockid:", device["btlockid"] ?? "-",
              "MACID:",    device["MACID"]    ?? "-",
              "LockCode:", device["LockCode"] ?? "MISSING")
    }
}
```

- `LockCode` present → use it directly as `macId`.
- `LockCode` missing (expected — Android's device-list bean has no such field) → call
  `getlockmacdetails` yourself with `URLSession`, passing the `btlockid` from the list,
  and read `LockCode` from the response.

Tell me which of the two it is and I will fold the result into section 9.2 of the
client document.

---

## Stage 4 — Advertisement dump (the critical unknown)

Android connects straight to a MAC. iOS cannot, so the SDK has to recognise the lock
from its advertisement. **Whether your V7 firmware publishes its MAC there is not
something I could determine from the code** — this test decides whether the
implementation works as written or needs the manual pairing path.

Power on one V7 lock, keep it within a metre or two of the phone, and run:

```swift
import SafeOBuddyV7
import CoreBluetooth

let targetMac = "5C:53:10:4F:37:AE"   // MACID of the lock in front of you

let target = PacketBuilder.normalizedMacBytes(targetMac)!
let fwd = PacketBuilder.bytesToHex(target).replacingOccurrences(of: " ", with: "")
let rev = PacketBuilder.bytesToHex(target.reversed()).replacingOccurrences(of: " ", with: "")
print("looking for \(fwd) or \(rev)")

SafeobuddyV7.manager.startScan { peripheral, adv, rssi in
    let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "-"
    let mfg  = (adv[CBAdvertisementDataManufacturerDataKey] as? Data)
                   .map { PacketBuilder.bytesToHex([UInt8]($0)) } ?? "none"

    print("""
    ---------------------------------------------
    name : \(name)
    uuid : \(peripheral.identifier.uuidString)
    rssi : \(rssi)
    mfg  : \(mfg)
    """)

    if mfg.replacingOccurrences(of: " ", with: "").contains(fwd) ||
       mfg.replacingOccurrences(of: " ", with: "").contains(rev) {
        print(">>> MAC FOUND IN ADVERTISEMENT — automatic discovery will work")
    }
}
```

Read the output carefully:

- **`>>> MAC FOUND`** — automatic discovery works. Go to Stage 5.
- **MAC appears in the `name`** (e.g. `V7_4F37AE`) — also handled automatically. Go to Stage 5.
- **MAC appears nowhere** — automatic discovery cannot work, and this is expected on
  some firmware. The lock must be paired once through your own UI:

  ```swift
  // after the user picks the correct row from your scan list
  SafeobuddyV7.manager.register(macAddress: targetMac,
                                peripheralIdentifier: peripheral.identifier)
  ```

  Identify the right row by signal strength — hold the phone against the lock and
  take the entry with the `rssi` closest to zero (e.g. `-35` beats `-80`).
  After registering once, `openLock` connects directly and never scans again.

Call `SafeobuddyV7.manager.stopScan()` when finished.

---

## Stage 5 — Open and close

```swift
SafeobuddyV7.openLock(macId: targetMac, onStatus: { print("[V7]", $0) }) { result in
    print("[V7] code =", result.code, "| message =", result.message, "| type =", result.type)
}
```

A healthy run prints:

```
[V7] Connecting…
[V7] Scanning for lock…          <- only on the very first open
[V7] Lock found, connecting…
[V7] Connected, discovering services…
[V7] Sending command…
[V7] code = 106 | message = Lock opened successfully. | type = open lock
```

Check the physical lock — **`106` means the packet was delivered, not that the lock
moved.** A write-without-response has no acknowledgement, so the SDK reports success
once the Bluetooth stack accepts the command. Only your eyes on the hardware confirm
the lock actually operated.

Then repeat with `closeLock`, and run the second open to confirm the peripheral cache
works (the `Scanning for lock…` line should not appear).

### If it fails

| Message | Meaning | What to do |
|---|---|---|
| `Lock … not found in range` | Scan timed out without a MAC match | Stage 4 outcome 3 — register manually |
| `No writable characteristic found` | Connected, but the GATT table has no writable characteristic | Send me the service/characteristic UUIDs; the firmware may need a specific one |
| `Timed out connecting` | Lock seen but will not accept a connection | Out of range, low battery, or already connected to another phone |
| `Bluetooth is turned off` / `permission denied` | Radio or permission | Check `NSBluetoothAlwaysUsageDescription` in Info.plist |
| Reports `106` but the lock does not move | Packet delivered to the wrong characteristic | Most likely cause: the first writable characteristic is not the command one. Send me the GATT dump |

---

## Stage 6 — Coexistence with the existing flow

Confirms the new module has not disturbed the shipping SDK.

1. **Old path alone.** In a build **without** `SafeOBuddyV7` in the Podfile, run a
   normal `Safeobuddy.openLock(deviceCode:)` against a TTLock device. This is the
   baseline — it must behave exactly as it does today.
2. **Add the pod, do not call it.** Add `pod 'SafeOBuddyV7'`, rebuild, repeat step 1.
   Behaviour must be identical. Nothing in the V7 module is constructed until one of
   its methods is called, so a difference here would be a real defect — report it.
3. **After a V7 action.** Run a V7 open, then `SafeobuddyV7.shutdown()`, then a
   standard `Safeobuddy.openLock`. The standard flow must work normally.
4. **Overlap (expected to degrade).** Start a V7 open and immediately trigger a
   standard `openLock`. Both use the same radio, so the standard one may be slower or
   time out. This is why `SafeobuddyV7.isBusy` exists — guard with it in the app.

---

## Before sending the document to the client

- [ ] Stage 1 passes — the V7 code compiles
- [ ] Stage 3 done — success code confirmed as `600` (or the document corrected)
- [ ] Stage 5 done — a real lock opens and closes
- [ ] Full error-code table supplied for section 10.A, or the section left as the
      general contract it currently states
- [ ] **Git tag `1.0.12` pushed** — `SafeOBuddy.podspec` declares it, but the repo's
      tags stop at `1.0.8`, so `pod install` fails for the client today
- [ ] **Git tag `v7-1.0.0` pushed** — same problem for `SafeOBuddyV7.podspec`
- [ ] Section 9 (V7) kept or removed depending on whether Stage 5 passed
