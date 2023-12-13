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
pod 'SafeOBuddy', :git => https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git
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
Safeobuddy.getDeviceRecord(deviceName: "your device Name", deviceID: "Your Device Id") { response, message, statusCode in
    if statusCode == 600 {
        print("Lock Records:", response)
    } else {
        print("Failed to fetch lock records:", message)
    }
}

Safeobuddy.getFilterDeviceRecord(deviceName: "Your Device Name", deviceID: "Your Device Name", fromDate: "mm/DD/yyyy", todayDate: "mm/DD/yyyy") { response, message, status in
    if status == 600 {
        print("Filtered Lock Records:", response)
    } else {
        print("Failed to fetch filtered lock records:", message)
    }
}
```


### 6. Open Lock

```
Safeobuddy.openLock(lockData: "Your Device's LockData", deviceCode: "Your Device's Code", deviceName: "Your Device Name") { response, message, statusCode in
    if statusCode == 600 {
        print("Lock opened successfully:", message)
    } else {
        print("Failed to open lock:", message)
    }
}
```

### 7. Close Lock

```
Safeobuddy.closeLock(lockData: "Your Device's LockData", deviceCode: "Your Device's Code", deviceName: "Your Device Name") { response, message, statusCode in
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

