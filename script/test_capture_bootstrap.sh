#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise the installer function without loading a service, waiting, or requiring root.
bootstrap_source="$(/usr/bin/sed -n '/^bootstrap_capture() {$/,/^}$/p' "$ROOT_DIR/dist/pkg/postinstall")"
[ -n "$bootstrap_source" ]
bootstrap_source="${bootstrap_source//\/bin\/launchctl/fake_launchctl}"
bootstrap_source="${bootstrap_source//\/usr\/bin\/perl/fake_pause}"
eval "$bootstrap_source"

PLIST=/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist
fake_launchctl() {
    [ "$#" -eq 3 ] && [ "$1" = bootstrap ] && [ "$2" = system ] && [ "$3" = "$PLIST" ] \
        || exit 1
    calls=$((calls + 1))
    [ "$calls" -gt "$failures" ]
}
fake_pause() {
    pauses=$((pauses + 1))
}

calls=0 pauses=0 failures=0
bootstrap_capture
[ "$calls" -eq 1 ] && [ "$pauses" -eq 0 ]

calls=0 pauses=0 failures=2
bootstrap_capture
[ "$calls" -eq 3 ] && [ "$pauses" -eq 2 ]

calls=0 pauses=0 failures=5
if bootstrap_capture; then
    echo 'Persistent registration failure must propagate to installer rollback' >&2
    exit 1
fi
[ "$calls" -eq 5 ] && [ "$pauses" -eq 4 ]

echo 'capture bootstrap policy: PASS'
