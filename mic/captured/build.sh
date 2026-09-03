#!/bin/bash
# Build the SiriRemote capture daemon. Pure libSystem — libnotify and
# libdispatch need no extra link flags.
set -euo pipefail
cd "$(dirname "$0")"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
CAPTURE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/siriremote-capture-test.XXXXXX")"
trap '/bin/rm -rf "$CAPTURE_TEST_DIR"' EXIT
clang -O2 -Wall -Wextra -Werror \
    srm_capture_demand_test.c -o "$CAPTURE_TEST_DIR/srm_capture_demand_test"
"$CAPTURE_TEST_DIR/srm_capture_demand_test"
clang -O2 -Wall -Wextra -Werror \
    srm_runtime_directory_test.c -o "$CAPTURE_TEST_DIR/srm_runtime_directory_test"
"$CAPTURE_TEST_DIR/srm_runtime_directory_test"
clang -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    srm_captured.c -o SiriRemoteCapture
security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\"" || {
    echo "required signing identity is unavailable: $SIGN_IDENTITY" >&2
    exit 1
}
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" SiriRemoteCapture
codesign --verify --strict --verbose=2 SiriRemoteCapture
echo "✓ built SiriRemoteCapture"
