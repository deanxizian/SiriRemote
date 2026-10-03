#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(/usr/bin/mktemp -d /private/tmp/siriremote-voice-coordinator.XXXXXX)"
cleanup() {
    /bin/rm -f "$TEST_WORK/VoiceCoordinatorTests"
    /bin/rmdir "$TEST_WORK"
}
trap cleanup EXIT

# Compile the actual App adapter, replacing only platform effects with isolated test doubles.
/usr/bin/swiftc -warnings-as-errors \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/RemoteVoiceSession.swift" \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/VoiceSession.swift" \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/VoiceTarget.swift" \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/VoiceKeyLatch.swift" \
    "$ROOT_DIR/SiriRemoteCore/Sources/SiriRemoteCore/VoiceShortcutController.swift" \
    "$ROOT_DIR/app/VoiceCoordinator.swift" \
    "$ROOT_DIR/script/test_voice_coordinator.swift" \
    -o "$TEST_WORK/VoiceCoordinatorTests"
"$TEST_WORK/VoiceCoordinatorTests"
