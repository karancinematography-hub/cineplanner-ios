#!/bin/bash
set -euo pipefail

mode="${1:-unsigned}"
if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
  cat <<'USAGE'
Run on a Mac with Xcode, Flutter 3.47.9 and CocoaPods.
bash scripts/build_ios.sh prepare
bash scripts/build_ios.sh unsigned
bash scripts/build_ios.sh simulator
bash scripts/build_ios.sh ipa [flutter build ipa options]
USAGE
  exit 0
fi
case "$mode" in
  prepare|unsigned|simulator|ipa) ;;
  *) printf 'Unknown build mode: %s\n' "$mode" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'The iOS build requires macOS and Xcode.' >&2
  exit 1
fi
for command in xcodebuild xcrun flutter pod; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Install the required build tool: %s\n' "$command" >&2
    exit 1
  fi
done

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root/apps/mobile_flutter"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path >/dev/null
flutter --version
flutter pub get --enforce-lockfile

case "$mode" in
  prepare)
    flutter build ios --config-only --no-codesign
    (cd ios && pod install)
    printf '%s\n' 'Open apps/mobile_flutter/ios/Runner.xcworkspace in Xcode.'
    ;;
  unsigned)
    flutter build ios --release --no-codesign
    printf '%s\n' 'Unsigned build created in apps/mobile_flutter/build/ios/iphoneos/. Signing is required to install on a device.'
    ;;
  simulator)
    flutter build ios --simulator --debug
    printf '%s\n' 'Simulator build created in apps/mobile_flutter/build/ios/iphonesimulator/.'
    ;;
  ipa)
    flutter build ipa --release "${@:2}"
    printf '%s\n' 'Archive and exported IPA are in apps/mobile_flutter/build/ios/.'
    ;;
esac
