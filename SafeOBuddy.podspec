#
#  Be sure to run `pod spec lint SafeOBuddy.podspec' to ensure this is a
#  valid spec and to remove all comments including this before submitting the spec.
#
#  To learn more about Podspec attributes see https://guides.cocoapods.org/syntax/podspec.html
#  To see working Podspecs in the CocoaPods repo see https://github.com/CocoaPods/Specs/
#

Pod::Spec.new do |s|


  s.name         = "SafeOBuddy"
  s.version      = "1.0.4"
  s.summary      = "It is a custom framework of Safeobuddy"
  s.description  = "It is a custom framework of Safeobuddy. This SDK is for digital locks"

  s.homepage     = "https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK"

  s.license      = "MIT"

  s.author      = { "iOS Team" => "gdhanuka@gmail.com" }

  s.platform     = :ios, "13.0"

  s.swift_versions = "5.0"

  s.source       = { :git => "https://github.com/DhanukaElectrotech/SafeOBuddy-iOS-SDK.git", :tag => "1.0.4" }

 s.static_framework = true

 s.vendored_frameworks = "SafeOBuddy/SafeOBuddy.framework"
 s.preserve_paths      = "SafeOBuddy/SafeOBuddy.framework"

 s.dependency "TTLock"
  

end