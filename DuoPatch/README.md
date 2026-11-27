# DuoPatch for iOS

Open DuoPatch.xcodeproj in Xcode 16 or newer on a Mac. Allow Xcode to resolve ZIPFoundation 0.9.20. For a physical device, choose your development team under Signing & Capabilities and set a unique bundle identifier. Select an iPhone or iPad running iOS 16 or later and press Run.

Tap **Choose decrypted IPA** and select a file. After processing, tap **Save to Files**. Allow room for temporary archive copies and the uncompressed main executable. Re-sign the exported IPA using your normal signing workflow before installing it.

DuoPatch writes exactly 27.2 to the SDK field of the main arm64/arm64e iOS executable, including universal slices. It also sets DTSDKName and DTPlatformVersion in the main Info.plist. The deployment target, frameworks, extensions and app code keep their original values. A newer SDK value is lowered to 27.2 if the executable's deployment target permits it. Changing this metadata cannot add missing APIs or guarantee correct layout. No system database access is required.
