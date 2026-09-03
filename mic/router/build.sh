#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PINNED_OPUS_PREFIX="$(../../dist/build-opus.sh)"
OPUS_PREFIX="${SIRIREMOTE_OPUS_PREFIX:-$PINNED_OPUS_PREFIX}"
OPUS_STATIC="$OPUS_PREFIX/lib/libopus.a"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
CODE_SIGN_TIMESTAMP="${SIRIREMOTE_CODESIGN_TIMESTAMP:-none}"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macosx$MACOS_MIN"
MODULE_CACHE="/private/tmp/srm-router-module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

case "$CODE_SIGN_TIMESTAMP" in
    none) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none) ;;
    secure) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp) ;;
    *)
        echo "SIRIREMOTE_CODESIGN_TIMESTAMP must be 'none' or 'secure'" >&2
        exit 2
        ;;
esac

[ -f "$OPUS_STATIC" ] || {
    echo "static libopus not found: $OPUS_STATIC" >&2
    echo "install it first: brew install opus" >&2
    exit 1
}

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MACOS_MIN" \
    SiriRemoteMicRingWriter.c \
    -o SiriRemoteMicRingWriter.o

swiftc \
    -warnings-as-errors \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -import-objc-header router_shim.h \
    -I"$OPUS_PREFIX/include" \
    "$OPUS_STATIC" \
    ../OpusVoiceDecoder.swift VoiceFrameParser.swift VoiceSequenceTracker.swift PklgTailReader.swift \
    SiriRemoteMicRouter.swift SiriRemoteMicRingWriter.o \
    -o SiriRemoteAudioRouter

security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\"" || {
    echo "required signing identity is unavailable: $SIGN_IDENTITY" >&2
    exit 1
}
codesign --force --options runtime "${CODE_SIGN_TIMESTAMP_ARGS[@]}" \
    --sign "$SIGN_IDENTITY" SiriRemoteAudioRouter
codesign --verify --strict --verbose=2 SiriRemoteAudioRouter

swiftc \
    -warnings-as-errors \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    VoiceFrameParser.swift VoiceSequenceTracker.swift PklgTailReader.swift test_parser.swift \
    -o test_parser

./test_parser
echo "router build: PASS"
