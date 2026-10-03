#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(/usr/bin/mktemp -d /private/tmp/siriremote-button-events.XXXXXX)"
cleanup() {
    /bin/rm -f "$TEST_WORK/ButtonEventTests"
    /bin/rmdir "$TEST_WORK"
}
trap cleanup EXIT

/usr/bin/swiftc -warnings-as-errors \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/FixedButtonHoldState.swift" \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/HeldButtonOutput.swift" \
    "$ROOT_DIR/app/HeldButtonEmitter.swift" \
    "$ROOT_DIR/script/test_button_events.swift" \
    -o "$TEST_WORK/ButtonEventTests"
"$TEST_WORK/ButtonEventTests"
