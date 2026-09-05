#!/bin/bash
# Build the SiriRemote capture daemon. Security validates the protected PacketLogger snapshot;
# libnotify and libdispatch are part of libSystem.
set -euo pipefail
cd "$(dirname "$0")"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
CODE_SIGN_TIMESTAMP="${SIRIREMOTE_CODESIGN_TIMESTAMP:-none}"
CAPTURE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/siriremote-capture-test.XXXXXX")"
trap '/bin/rm -rf "$CAPTURE_TEST_DIR"' EXIT
CAPTURE_OUTPUT="SiriRemoteCapture"
case "$CODE_SIGN_TIMESTAMP" in
    none) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none) ;;
    secure) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp) ;;
    *)
        echo "SIRIREMOTE_CODESIGN_TIMESTAMP must be 'none' or 'secure'" >&2
        exit 2
        ;;
esac
if [ "${SIRIREMOTE_COMPILE_ONLY:-0}" = "1" ]; then
    CAPTURE_OUTPUT="$CAPTURE_TEST_DIR/SiriRemoteCapture"
fi
clang -O2 -Wall -Wextra -Werror \
    srm_runtime_directory_test.c -o "$CAPTURE_TEST_DIR/srm_runtime_directory_test"
"$CAPTURE_TEST_DIR/srm_runtime_directory_test"
clang -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
    srm_audio_security_test.c -framework CoreFoundation -framework Security \
    -o "$CAPTURE_TEST_DIR/srm_audio_security_test"
"$CAPTURE_TEST_DIR/srm_audio_security_test"
clang -O2 -Wall -Wextra -Werror srm_capture_auth_test.c \
    -framework CoreFoundation -framework Security -o "$CAPTURE_TEST_DIR/srm_capture_auth_test"
"$CAPTURE_TEST_DIR/srm_capture_auth_test"
clang -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    srm_captured.c -framework CoreFoundation -framework Security -o "$CAPTURE_OUTPUT"
if [ "${SIRIREMOTE_COMPILE_ONLY:-0}" = "1" ]; then
    echo "✓ capture service compile-only build"
    exit 0
fi
security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\"" || {
    echo "required signing identity is unavailable: $SIGN_IDENTITY" >&2
    exit 1
}
codesign --force --options runtime "${CODE_SIGN_TIMESTAMP_ARGS[@]}" \
    --sign "$SIGN_IDENTITY" "$CAPTURE_OUTPUT"
codesign --verify --strict --verbose=2 "$CAPTURE_OUTPUT"
echo "✓ built SiriRemoteCapture"
