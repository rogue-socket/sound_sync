#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if SDK_PATH=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null) && SWIFTC_PATH=$(xcrun --find swiftc 2>/dev/null); then
  SDK="$SDK_PATH"
  SWIFTC="$SWIFTC_PATH"
else
  SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
fi
TARGET="arm64-apple-macosx15.0"

mkdir -p "$ROOT/build"

"$SWIFTC" -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -framework Foundation -framework Accelerate \
  "$ROOT/Sources/SoundSync/Correlation.swift" \
  "$ROOT/Sources/SoundSync/Tone.swift" \
  "$ROOT/Tests/CorrelationChecks.swift" \
  -o "$ROOT/build/correlation-tests"

"$ROOT/build/correlation-tests"

"$SWIFTC" -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -framework AppKit -framework SwiftUI -framework CoreAudio -framework AVFoundation \
  -framework IOBluetooth -framework Accelerate -framework IOKit \
  "$ROOT/Sources/SoundSync/"*.swift \
  -o "$ROOT/build/SoundSync.bin"

APP="$ROOT/build/SoundSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/build/SoundSync.bin" "$APP/Contents/MacOS/SoundSync"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

"$SWIFTC" -parse-as-library -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -framework Foundation -framework CoreAudio -framework Accelerate \
  "$ROOT/Sources/SoundSync/CoreAudioSupport.swift" \
  "$ROOT/Sources/SoundSync/SharedClock.swift" \
  "$ROOT/Sources/SoundSync/SystemAudioTap.swift" \
  "$ROOT/Tests/TapSmoke.swift" \
  -o "$ROOT/build/tap-smoke"

"$ROOT/build/tap-smoke"
