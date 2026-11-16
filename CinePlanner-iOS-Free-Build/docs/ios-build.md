# CinePlanner on iPhone and iPad

The iOS target is prepared for iOS and iPadOS 15 or later. This source package was checked on Windows. Native Xcode compilation, signing, and device testing are still pending.

## Build on macOS

Use Flutter 3.47.9, Xcode with the iOS SDK, and CocoaPods. Open Terminal in the extracted package directory and run the following.

```bash
bash scripts/build_ios.sh prepare
open apps/mobile_flutter/ios/Runner.xcworkspace
```

In Xcode, select the Runner target and choose your Apple development team under Signing & Capabilities. Keep automatic signing enabled. The proposed bundle identifier is `app.cineplanner.cineplanner`. Register that identifier with your team or replace it with one you own. Keep the same identifier on subsequent installs to retain access to the app's saved workspace and Keychain entries.

Connect your iPad, select it as the destination, and use Product → Run to install a development build. Trust the development team and enable Developer Mode on the iPad if prompted.

For an unsigned compilation check on a Mac, run the following.

```bash
bash scripts/build_ios.sh unsigned
```

After configuring signing, export an IPA with the appropriate provisioning method.

```bash
# Development signing for a device registered with your Apple team
bash scripts/build_ios.sh ipa --export-method development

# App Store Connect / TestFlight distribution
bash scripts/build_ios.sh ipa --export-method app-store
```

Flutter writes the archive under `apps/mobile_flutter/build/ios/archive/` and the exported IPA under `apps/mobile_flutter/build/ios/ipa/`. A distribution certificate, provisioning profile, and Apple Developer membership are required for the relevant distribution method. Upload through Xcode Organizer or Apple Transporter, then add the processed build to a TestFlight group in App Store Connect.

The build command runs CocoaPods because the encrypted database dependency uses native pods. The first Mac build will resolve these pods and produce `ios/Podfile.lock`. Retain that lockfile with the resulting build for repeatability.

## Platform configuration

- The native target supports iPhone and iPad, with camera and photo-library usage descriptions and Keychain access for the encrypted workspace key.
- iPhone declares both landscape orientations. The initial iPad view requests landscape on iPadOS 16 or later. iPad retains support for all orientations and window resizing, so the operating system can choose the orientation in multitasking. Check the initial orientation on a physical iPad.
- Light Plan has a Back control on iOS. Existing tablet layouts and touch scrollers are shared with Android.
- Camera recovery requests Android lost-image results only on Android. Available staged capture files remain recoverable on iOS.
- The iOS icon set currently uses Flutter's generated placeholder icons.

## iPad acceptance checks

- [ ] Install through Xcode or TestFlight and open in landscape. Verify cold launch, safe areas, portrait adaptation, and resized windows.
- [ ] Create a sample project and take. Force-close and reopen to verify that Keychain access and SQLCipher preserve the workspace.
- [ ] Check Scene, Shot, and Take scrollers, the Take slider, Go to, and Back navigation.
- [ ] Allow camera access and take a photo in each grab. Repeat with permission denied and with a cancelled capture.
- [ ] Import images through Files. Export the current PDF through the share sheet and save it to Files.
- [ ] Test Reset, Undo, and Redo, then confirm independent takes after an offline restart.
- [ ] Check camera capture and PDF sharing on a physical iPad. Simulator checks cannot validate all camera behavior.

## References

- [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup)
- [Flutter iOS build and distribution](https://docs.flutter.dev/deployment/ios)
- [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Apple iPad window and orientation guidance](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)
