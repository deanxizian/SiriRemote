#!/bin/bash
# Compile + run the OpusVoiceDecoder offline self-test.
# Uses the same pinned static Opus build as the shipping router.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && /bin/pwd -P)"

OPUS_PREFIX="${SIRIREMOTE_OPUS_PREFIX:-$(../dist/build-opus.sh)}"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
MODULE_CACHE="/private/tmp/srm-opus-module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swiftc \
    -warnings-as-errors \
    -sdk "$SDK_PATH" \
    -import-objc-header opus_shim.h \
    -I"$OPUS_PREFIX/include" \
    "$OPUS_PREFIX/lib/libopus.a" \
    OpusVoiceDecoder.swift test_decoder.swift \
    -o test_decoder

./test_decoder
