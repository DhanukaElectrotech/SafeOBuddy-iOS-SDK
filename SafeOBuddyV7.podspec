#
#  SafeOBuddyV7 — direct-BLE lock control (V7 locks).
#
#  Shipped as a SEPARATE pod from `SafeOBuddy` on purpose: the main pod
#  vendors SafeOBuddy.framework, which already declares a Clang module named
#  `SafeOBuddy`. Adding `source_files` to that podspec would make CocoaPods
#  generate a second module with the same name and the build would fail with
#  "redefinition of module 'SafeOBuddy'".
#
#  This pod is standalone — it does not link against SafeOBuddy.framework or
#  TTLock. Add both pods when you need the cloud API and the V7 BLE path.
#
#      pod 'SafeOBuddy',   :git => 'https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git'
#      pod 'SafeOBuddyV7', :git => 'https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git'
#

Pod::Spec.new do |s|

  s.name         = "SafeOBuddyV7"
  s.version      = "1.0.0"
  s.summary      = "Direct BLE control for SafeOBuddy V7 digital locks"
  s.description  = <<-DESC
                   CoreBluetooth implementation of the SafeOBuddy V7 lock-open
                   process: build the 7-byte MAC-derived control packet, find the
                   lock, connect, write the packet to its writable characteristic
                   and disconnect. Port of the Android SDK's BleLockManager and
                   PacketBuilder.
                   DESC

  s.homepage     = "https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK"

  s.license      = "MIT"

  s.author       = { "iOS Team" => "gdhanuka@gmail.com" }

  s.platform     = :ios, "13.0"

  s.swift_versions = "5.0"

  s.source       = { :git => "https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git", :tag => "v7-1.0.0" }

  s.source_files = "Sources/SafeOBuddyV7/**/*.swift"

  s.frameworks   = "CoreBluetooth", "Foundation"

end
