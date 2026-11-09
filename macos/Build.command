#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
cd "$ROOT"
mkdir -p "$ROOT/.build"
exec > >(tee "$ROOT/.build/build.log") 2>&1
trap 'echo "Build did not finish. Keep .build/build.log and share the compiler error for help."' ERR
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Build this kit on an Apple Silicon Mac, from a native (not Rosetta) Terminal."; exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 15 )); then
  echo "macOS 15 or newer is required."; exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Install Apple's Command Line Tools or Xcode 16 or newer, then retry."
  echo "Apple's installer can be opened with: xcode-select --install"; exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${SDK_VERSION%%.*} < 15 )); then
  echo "Select an Xcode/Command Line Tools installation with the macOS 15 SDK or newer."; exit 1
fi
if pgrep -x LocalMeetingNotes >/dev/null; then
  echo "Close Local Meeting Notes before rebuilding it."; exit 1
fi
if [[ ! -f "$ROOT/Models/ggml-small-q5_1.bin" || ! -f "$ROOT/Vendor/whisper-macos.zip" || ! -f "$ROOT/COMPONENT-SHA256.txt" ]]; then
  bash "$ROOT/Fetch-Assets.command"
fi
shasum -a 256 -c "$ROOT/COMPONENT-SHA256.txt"
BUILD="$(mktemp -d "$ROOT/.build/build.XXXXXX")"
TEST_DIR="$BUILD/storage-checks"
mkdir -p "$TEST_DIR"
echo "Checking recording storage and recovery..."
xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target arm64-apple-macosx15.0 \
  "$ROOT/Source/Storage.swift" "$ROOT/Tests/StorageTests.swift" -o "$BUILD/storage-checks-tool"
TEST_ARGS=("$TEST_DIR")
if [[ "${1:-}" == --long-tests ]]; then TEST_ARGS+=(--long); fi
"$BUILD/storage-checks-tool" "${TEST_ARGS[@]}"
mkdir -p "$BUILD/vendor"
ditto -x -k "$ROOT/Vendor/whisper-macos.zip" "$BUILD/vendor"
APP="$BUILD/Local Meeting Notes.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Models" "$CONTENTS/Resources/Licenses" "$CONTENTS/Frameworks"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Models/ggml-small-q5_1.bin" "$CONTENTS/Resources/Models/"
ditto "$ROOT/Licenses" "$CONTENTS/Resources/Licenses"
cp "$ROOT/Read me.txt" "$CONTENTS/Resources/Read me.txt"
ditto "$BUILD/vendor/whisper.framework" "$CONTENTS/Frameworks/whisper.framework"
FRAMEWORK="$CONTENTS/Frameworks/whisper.framework"
xcrun lipo "$FRAMEWORK/Versions/A/whisper" -thin arm64 -output "$BUILD/whisper-arm64"
cp "$BUILD/whisper-arm64" "$FRAMEWORK/Versions/A/whisper"
echo "Building the local Apple Silicon transcription helper..."
xcrun --sdk macosx clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 -isysroot "$SDK" \
  -F "$CONTENTS/Frameworks" -framework whisper -Wl,-rpath,@executable_path/../Frameworks \
  "$ROOT/Source/TranscribeHelper.cpp" -o "$CONTENTS/MacOS/transcribe-helper"
echo "Building the native macOS app..."
xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target arm64-apple-macosx15.0 \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  "$ROOT/Source/Storage.swift" "$ROOT/Source/Capture.swift" "$ROOT/Source/App.swift" -o "$CONTENTS/MacOS/LocalMeetingNotes"
IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then SIGN_ARGS+=(--options runtime --timestamp); else SIGN_ARGS+=(--timestamp=none); fi
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$CONTENTS/MacOS/transcribe-helper"
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
"$CONTENTS/MacOS/transcribe-helper" --check-model "$CONTENTS/Resources/Models/ggml-small-q5_1.bin"
mkdir -p "$ROOT/dist"
if [[ -e "$ROOT/dist/Local Meeting Notes.app" ]]; then
  mv "$ROOT/dist/Local Meeting Notes.app" "$ROOT/.build/previous-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$APP" "$ROOT/dist/Local Meeting Notes.app"
PACKAGE="$ROOT/dist/LocalMeetingNotes-macOS-AppleSilicon.zip"
if [[ -e "$PACKAGE" ]]; then mv "$PACKAGE" "$ROOT/.build/previous-package-$(date +%Y%m%d-%H%M%S).zip"; fi
ditto -c -k --keepParent "$ROOT/dist/Local Meeting Notes.app" "$PACKAGE"
echo ""
echo "Built: $ROOT/dist/Local Meeting Notes.app"
echo "Distribution ZIP: $PACKAGE"
echo "Move the app to Applications before its first launch. Grant its system-audio and microphone permissions yourself."
echo "Local builds are ad-hoc signed unless SIGNING_IDENTITY is provided; this script does not notarize the app."

