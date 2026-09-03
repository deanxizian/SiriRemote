#!/bin/bash
# Build the "Siri Remote Mic" CoreAudio HAL plug-in (an AudioServerPlugIn bundle).
# No Xcode project needed — a HAL plug-in is just a bundle with a compiled dylib.
# Source is the Siri Remote Mic fork; our config is injected with -include.
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
DRIVER="SiriRemoteAudio.driver"
EXE="SiriRemoteAudio"
CAPTURE_APP="SiriRemoteMicCaptureTest.app"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
DRIVER_VERSION="${SIRIREMOTE_VERSION:-0.1.0}"
BUILD_NUMBER="${SIRIREMOTE_BUILD_NUMBER:-1}"
DRIVER_SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
# Optional stable signing identity for the capture-test app (keeps its microphone TCC grant across
# rebuilds). Set SRM_CAPTURE_SIGN_IDENTITY to your own "Apple Development: …" identity; unset → ad-hoc.
CAPTURE_SIGN_IDENTITY="${SRM_CAPTURE_SIGN_IDENTITY:-}"

if ! [[ "$DRIVER_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "invalid SIRIREMOTE_VERSION: $DRIVER_VERSION" >&2
    exit 2
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "invalid SIRIREMOTE_BUILD_NUMBER: $BUILD_NUMBER" >&2
    exit 2
fi

rm -rf "$DRIVER"
rm -rf "$CAPTURE_APP"
mkdir -p "$DRIVER/Contents/MacOS"
mkdir -p "$CAPTURE_APP/Contents/MacOS"
cp Info.plist "$DRIVER/Contents/Info.plist"
cp CaptureTest-Info.plist "$CAPTURE_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DRIVER_VERSION" \
    "$DRIVER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$DRIVER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOS_MIN" \
    "$DRIVER/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MACOS_MIN" \
        "$DRIVER/Contents/Info.plist"

clang -bundle -O2 \
    -Wall -Wextra -Werror \
    -isysroot "$SDK" \
    -mmacosx-version-min="$MACOS_MIN" \
    -include SiriRemoteMic.config.h \
    SiriRemoteMic.c \
    -framework CoreFoundation -framework CoreAudio -framework Accelerate \
    -o "$DRIVER/Contents/MacOS/$EXE"

clang -O2 -Wall -Wextra -Werror srm_test_writer.c -o srm_test_writer
clang -O2 -Wall -Wextra -Werror srm_capture_test.c \
    -framework CoreFoundation -framework CoreAudio \
    -o "$CAPTURE_APP/Contents/MacOS/SiriRemoteMicCaptureTest"
clang -O2 -Wall -Wextra -Werror srm_usage_monitor.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_usage_monitor
clang -O2 -Wall -Wextra -Werror srm_notify_listener.c -o srm_notify_listener
clang -O2 -Wall -Wextra -Werror srm_driver_contract_test.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_driver_contract_test
clang -O2 -Wall -Wextra -Werror -isysroot "$SDK" srm_io_sim.c \
    -framework CoreFoundation -framework CoreAudio \
    -o srm_io_sim

# The product's system components share one Developer ID identity and opt into the hardened
# runtime. Fail closed: silently switching identity would make upgrades and trust diagnostics
# nondeterministic.
CODE_SIGN_TIMESTAMP="${SIRIREMOTE_CODESIGN_TIMESTAMP:-none}"
case "$CODE_SIGN_TIMESTAMP" in
    none) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none) ;;
    secure) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp) ;;
    *)
        echo "SIRIREMOTE_CODESIGN_TIMESTAMP must be 'none' or 'secure'" >&2
        exit 2
        ;;
esac
security find-identity -v -p codesigning | grep -Fq "\"$DRIVER_SIGN_IDENTITY\"" || {
    echo "required signing identity is unavailable: $DRIVER_SIGN_IDENTITY" >&2
    exit 1
}
codesign --force --options runtime "${CODE_SIGN_TIMESTAMP_ARGS[@]}" \
    --sign "$DRIVER_SIGN_IDENTITY" "$DRIVER"
if [ -n "$CAPTURE_SIGN_IDENTITY" ] && security find-identity -v -p codesigning | grep -Fq "\"$CAPTURE_SIGN_IDENTITY\""; then
    codesign --force --sign "$CAPTURE_SIGN_IDENTITY" "$CAPTURE_APP"
    echo "✓ capture test signed with stable development identity"
else
    codesign --force --sign - "$CAPTURE_APP"
    echo "! capture test ad-hoc signed (set SRM_CAPTURE_SIGN_IDENTITY for stable TCC identity)"
fi

echo "✓ built $DRIVER"
codesign -dv "$DRIVER" 2>&1 | grep -E 'Identifier|Signature' || true
"./srm_driver_contract_test" "$DRIVER/Contents/MacOS/$EXE"
# coreaudiod-style IO simulation: proves stereo ReadInput continuity, idempotency under a second
# client, resync recovery, clean silence with no A2854 producer, and no unrelated-source leakage.
"./srm_io_sim" "$DRIVER/Contents/MacOS/$EXE"
echo "system installation is owned by the verified packages in ../../dist"
