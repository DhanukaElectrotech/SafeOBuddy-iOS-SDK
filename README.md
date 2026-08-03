

# SafeOBuddy - iOS SDK Documentation

## Overview

Welcome to SafeOBuddy, the iOS SDK designed to empower you in managing digital locks seamlessly. This SDK provides a set of functionalities to integrate digital lock management into your iOS applications, making it easy to control and monitor access to devices.

## Implementation

### Environment (Minimum requirements):

- XCode 14.0, iOS 13.0, Swift 5.0

### Before calling SDK API:

- Ensure Bluetooth is enabled on the device.
  - Set Permissions in the Info.plist file:
    - Privacy - Bluetooth Peripheral Usage Description
    - Privacy - Bluetooth Always Usage Description

### Installation:

Add the following line to your app’s Pod file:

```
pod 'SafeOBuddy', :git => 'https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git'
```

After running pod install, make sure to add import SafeOBuddy at the top of your class file.

### 1. Initialization

Initialize the SDK in your AppDelegate file within the didFinishLaunchingWithOptions method:

```
Safeobuddy.intializeSafeobuddy { message in
    print("SDK initialized:", message)
}
 ```

### 3. Authorization

Authorize the SDK after initialization:

```
Safeobuddy.authUser(email: "your Email", password: "your password") { response, message, status in
    if status == 600 {
        print("Authorization successful!")
    } else {
        print("Authorization failed:", message)
    }
}
```

### 4. Device List

```
Safeobuddy.getDeviceList { deviceList, message, statusCode in
    if statusCode == 600 {
        print("Device List:", deviceList)
    } else {
        print("Failed to fetch device list:", message)
    }
}
```

### 5. Lock Records

Lock records (default 30 days records):

```
Safeobuddy.getDeviceRecord(deviceName: "your device Name") { response, message, statusCode in
    if statusCode == 600 {
        print("Lock Records:", response)
    } else {
        print("Failed to fetch lock records:", message)
    }
}

Safeobuddy.getFilterDeviceRecord(deviceName: "Your Device Name", fromDate: "mm/DD/yyyy", todayDate: "mm/DD/yyyy") { response, message, status in
    if status == 600 {
        print("Filtered Lock Records:", response)
    } else {
        print("Failed to fetch filtered lock records:", message)
    }
}
```


### 6. Open Lock

```
Safeobuddy.openLock(deviceName: "Your Device Name") { response, message, statusCode in
    if statusCode == 600 {
        print("Lock opened successfully:", message)
    } else {
        print("Failed to open lock:", message)
    }
}
```

### 7. Close Lock

```
Safeobuddy.closeLock(deviceName: "Your Device Name") { response, message, statusCode in
    if statusCode == 600 {
        print("Lock closed successfully:", message)
    } else {
        print("Failed to close lock:", message)
    }
}
```


### 8. Logout user

```
Safeobuddy.logout() { message in
    print("User logged out:", message)
}
```

---

## V7 Locks — Direct BLE Open/Close

V7 locks are not driven through the TTLock cloud. The app talks to the lock
directly over BLE: it builds a 7-byte packet from the lock's MAC and writes it to
the lock's writable characteristic. This is the iOS port of the Android SDK's
`BleLockManager` / `PacketBuilder` (`safesdk/.../newV7lock/`) and of
`SafeLock.openV7Lock` / `closeV7Lock`.

It ships as a **separate pod**, `SafeOBuddyV7`, because `SafeOBuddy.framework`
already declares a Clang module named `SafeOBuddy` — adding source files to the
main podspec would collide with it.

```
pod 'SafeOBuddy',   :git => 'https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git'
pod 'SafeOBuddyV7', :git => 'https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git'
```

### Permissions

Add to Info.plist:

- `NSBluetoothAlwaysUsageDescription`

iOS does **not** need location permission for BLE (the Android SDK's GPS check
has no iOS counterpart).

### The packet

Identical to Android. MAC `5C:53:10:4F:37:AE`, byte-reversed, first 6 bytes,
plus the command byte — `0x55` open, `0x4C` lock:

```
AE 37 4F 10 53 5C 55     <- open
AE 37 4F 10 53 5C 4C     <- lock
```

### Open / close

```swift
import SafeOBuddyV7

// macId is the MACID returned by the backend device info.
SafeobuddyV7.openLock(macId: "5C:53:10:4F:37:AE") { result in
    if result.isSuccess {           // code "106"
        print(result.message)       // "Lock opened successfully."
    } else {                        // "102" open failed, "100" invalid device
        print(result.message)
    }
}

SafeobuddyV7.closeLock(macId: "5C:53:10:4F:37:AE") { result in
    print(result.code, result.message, result.type)
}
```

Codes, messages and the `type` string (`"open lock"` / `"close lock"`) match
Android's `onSafeLockAction` exactly, so result handling can be shared.

To follow progress:

```swift
SafeobuddyV7.openLock(macId: mac, onStatus: { print($0) }) { result in ... }
```

Android calls `updateLockStatus(...)` inline to push "Opened via APP" to the
backend. `SafeOBuddy.framework` does not expose that endpoint, so it is a hook:

```swift
SafeobuddyV7.onLockStatusUpdate = { macId, status in
    // status: "Opened via APP" / "Failed to open via APP" / …
}
```

### Finding the lock — the one real difference from Android

Android connects straight to a MAC with `BluetoothAdapter.getRemoteDevice(mac)`.
**iOS has no such API** — CoreBluetooth never exposes a peripheral's MAC and will
only connect to a `CBPeripheral` produced by a scan.

So `BleLockManager` resolves the MAC itself: it scans and matches the MAC bytes
against each advertisement's manufacturer data, service data (forward *and*
byte-reversed) and advertised name. The first match is cached in `UserDefaults`,
so subsequent opens go straight to `retrievePeripherals(withIdentifiers:)` and
skip the scan.

If your V7 firmware does not put the MAC in its advertisement, resolve it once
from your own scan UI and register it:

```swift
SafeobuddyV7.manager.startScan { peripheral, advertisementData, rssi in
    // present the list, let the user pick the lock
}
SafeobuddyV7.manager.register(macAddress: mac, peripheralIdentifier: peripheral.identifier)
```

### Tuning

```swift
SafeobuddyV7.manager = BleLockManager(configuration: .init(
    scanTimeout: 15,
    connectTimeout: 15,
    discoveryTimeout: 10,
    writeWithoutResponseGrace: 0.6
))
```

`writeWithoutResponseGrace` has no Android equivalent: `gatt.disconnect()` flushes
pending writes, but iOS can tear the link down before a queued
write-without-response reaches the radio, so the disconnect is delayed briefly.

### Coexistence with the existing (TTLock) flow

The V7 module is additive. `SafeOBuddy.podspec` and `SafeOBuddy.framework` are
**not modified**, so an app that does not adopt `SafeOBuddyV7` behaves exactly as
before.

What was checked, and what it means:

| Shared surface | Status |
|---|---|
| Public type names | No overlap. `BleLockManager`, `PacketBuilder`, `LockCallback`, `SafeobuddyV7` do not exist in `SafeOBuddy.framework` — importing both modules is unambiguous. |
| ObjC runtime classes | Both are Swift `NSObject` subclasses in different modules, so their runtime names are module-mangled and cannot collide. |
| `UserDefaults` | The V7 peripheral cache lives in its own `com.safeobuddy.v7` suite, never in `UserDefaults.standard`. |
| BLE state restoration | `SafeOBuddy.framework` implements `centralManager:willRestoreState:`. The V7 manager deliberately has **no** restore identifier, so it is never revived in the background. |
| Info.plist | Needs only `NSBluetoothAlwaysUsageDescription`, which the existing SDK already requires. |
| Method swizzling / notifications / URL handling | None used. |

**The one genuine shared resource is the Bluetooth radio.**
`SafeOBuddy.framework` drives its own `CBCentralManager`. Two central managers in
one process are legal and fully independent — each vends its own `CBPeripheral`
objects, so the V7 module cannot touch the legacy SDK's connections or delegates.
But they share one antenna, and the V7 slow path uses an unfiltered scan to
resolve a MAC, which will slow a legacy connect running at the same time.

Three things follow:

1. **Nothing is created until you call a V7 API.** `SafeobuddyV7.manager` and its
   `CBCentralManager` are both constructed lazily, so an app that never calls the
   V7 path gets no second central manager, no scan and no extra battery cost.
2. **Do not run both paths concurrently.** Guard with `SafeobuddyV7.isBusy`
   before starting a legacy `Safeobuddy.openLock(...)`, and vice versa.
3. **Hand the radio back when you leave a V7 screen:**

```swift
SafeobuddyV7.shutdown()   // stops scanning, drops V7 connections, releases the central
```

The system "Turn On Bluetooth" alert is **off by default** for this module
(`Configuration.showPowerAlert`), so it never puts an alert on screen that the app
did not already show through the legacy flow.

### Delivery semantics

Same rules as the Android port:

- Write-without-response is preferred when the characteristic supports it — the
  command counts as delivered once the stack accepts it, since there is no ACK.
- For write-with-response, a disconnect arriving *after* the write went out but
  *before* the ACK is treated as **success**. This is the iOS equivalent of the
  Android port's "GATT status 133 is a false negative" rule: the lock acted and
  dropped the link before acknowledging.
- Success or failure is reported exactly once, on the main queue.



