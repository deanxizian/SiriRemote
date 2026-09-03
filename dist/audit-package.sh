#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
FULL_PKG="${1:-$ROOT/dist/out/SiriRemote-Full-Setup.pkg}"
UNINSTALL_PKG="${2:-$ROOT/dist/out/SiriRemote-Complete-Uninstall.pkg}"
EXPECTED_TEAM="96M7FW2XLU"
EXPECTED_AUTHORITY="Developer ID Application: ZIAN XI (96M7FW2XLU)"

[ -f "$FULL_PKG" ] || { echo "missing package: $FULL_PKG" >&2; exit 1; }
[ -f "$UNINSTALL_PKG" ] || { echo "missing package: $UNINSTALL_PKG" >&2; exit 1; }

AUDIT_DIR="$(/usr/bin/mktemp -d /private/tmp/siriremote-package-audit.XXXXXX)"
trap '/bin/rm -rf "$AUDIT_DIR"' EXIT
/usr/sbin/pkgutil --expand-full "$FULL_PKG" "$AUDIT_DIR/full"
/usr/sbin/pkgutil --expand-full "$UNINSTALL_PKG" "$AUDIT_DIR/uninstall"

PAYLOAD="$AUDIT_DIR/full/Payload"
APP="$PAYLOAD/Applications/SiriRemote.app"
DRIVER="$PAYLOAD/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver"
SUPPORT="$PAYLOAD/Library/Application Support/SiriRemote"
CAPTURE="$SUPPORT/SiriRemoteCapture"
ROUTER="$SUPPORT/SiriRemoteAudioRouter"
LAUNCHD="$PAYLOAD/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist"
PACKAGE_INFO="$AUDIT_DIR/full/PackageInfo"
WATCHDOG="$AUDIT_DIR/full/Scripts/SiriRemoteCoreAudioWatchdog"
PROCESS_VERIFIER="$AUDIT_DIR/full/Scripts/SiriRemoteProcessVerifier"
EN_INFO_STRINGS="$APP/Contents/Resources/en.lproj/InfoPlist.strings"
ZH_INFO_STRINGS="$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

for required in "$APP" "$DRIVER" "$CAPTURE" "$ROUTER" "$LAUNCHD" \
    "$EN_INFO_STRINGS" "$ZH_INFO_STRINGS" \
    "$AUDIT_DIR/full/Scripts/preinstall" "$AUDIT_DIR/full/Scripts/postinstall" "$WATCHDOG" \
    "$PROCESS_VERIFIER" \
    "$AUDIT_DIR/uninstall/Scripts/postinstall" \
    "$AUDIT_DIR/uninstall/Scripts/SiriRemoteShmCleanup"; do
    [ -e "$required" ] || { echo "package is missing $required" >&2; exit 1; }
done

/usr/bin/plutil -lint "$EN_INFO_STRINGS" "$ZH_INFO_STRINGS" >/dev/null

# The watchdog must be a bounded native sampler. The old ps/awk loop could block PackageKit for its
# full 600-second script ceiling precisely when CoreAudio was unhealthy.
/usr/bin/grep -Fq 'WATCH_WARMUP_SECONDS=' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'SiriRemoteCoreAudioWatchdog' "$AUDIT_DIR/full/Scripts/postinstall"
if /usr/bin/grep -Fq 'cpu_seconds_for_pids' "$AUDIT_DIR/full/Scripts/postinstall"; then
    echo "package still contains the blocking shell CPU sampler" >&2
    exit 1
fi
if /usr/bin/grep -Eq 'chown -R root:wheel "\$SUPPORT"|chmod -RN "\$SUPPORT"' \
    "$AUDIT_DIR/full/Scripts/postinstall"; then
    echo "postinstall must not recursively rewrite the protected PacketLogger snapshot" >&2
    exit 1
fi
/usr/bin/grep -Fq 'stop_siriremote_processes' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'requires a logged-in console user' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'verify_expected_signature "$APP" com.deanxi.siriremote' \
    "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'Developer ID Application: ZIAN XI (96M7FW2XLU)' \
    "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'verify_single_live_app "$console_uid"' \
    "$AUDIT_DIR/full/Scripts/postinstall"
if /usr/bin/grep -Fq '/private/var/tmp/com.deanxi.siriremote.install-backup' \
    "$AUDIT_DIR/full/Scripts/preinstall" "$AUDIT_DIR/full/Scripts/postinstall"; then
    echo "installer still uses the attacker-writable fixed rollback path" >&2
    exit 1
fi
/usr/bin/grep -Fq 'INSTALL_STATE="/private/var/run/com.deanxi.siriremote-installer"' \
    "$AUDIT_DIR/full/Scripts/preinstall"
/usr/bin/grep -Fq 'mktemp -d "$INSTALL_STATE/backup.XXXXXX"' \
    "$AUDIT_DIR/full/Scripts/preinstall"
/usr/bin/grep -Fq 'run_parent_mode_value & 0002' \
    "$AUDIT_DIR/full/Scripts/preinstall"
/usr/bin/grep -Fq 'load_backup_state' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'validate_restored_components' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'verify_launchdaemon' "$AUDIT_DIR/full/Scripts/postinstall"
/usr/bin/grep -Fq 'refusing to activate an invalid SiriRemote rollback' \
    "$AUDIT_DIR/full/Scripts/postinstall"
if /usr/bin/grep -Fq 'ps -p "$app_pids" -o command=' \
    "$AUDIT_DIR/full/Scripts/postinstall"; then
    echo "postinstall must verify the kernel process path, not mutable argv" >&2
    exit 1
fi
"$WATCHDOG" --self-test

# A relocatable App can be silently installed over a same-ID development bundle outside
# /Applications. This is a packaging failure even when the payload itself looks correct.
relocatable_count="$(/usr/bin/xmllint --xpath \
    'count(/pkg-info/relocate/bundle)' "$PACKAGE_INFO")"
if [ "$relocatable_count" != "0" ]; then
    echo "package contains relocatable bundles" >&2
    exit 1
fi
app_package_path="$(/usr/bin/xmllint --xpath \
    'string(/pkg-info/bundle[@id="com.deanxi.siriremote"]/@path)' "$PACKAGE_INFO")"
if [ "$app_package_path" != "./Applications/SiriRemote.app" ]; then
    echo "unexpected SiriRemote app package path: $app_package_path" >&2
    exit 1
fi

if /usr/bin/find "$AUDIT_DIR/full" "$AUDIT_DIR/uninstall" -name '._*' -print \
    | /usr/bin/grep -q .; then
    echo "AppleDouble metadata found in package" >&2
    exit 1
fi

assert_signature() {
    target="$1"
    identifier="$2"
    runtime="$3"
    /usr/bin/codesign --verify --strict --verbose=2 "$target"
    details="$(/usr/bin/codesign -d --verbose=4 "$target" 2>&1)"
    echo "$details" | /usr/bin/grep -Fq "Identifier=$identifier"
    echo "$details" | /usr/bin/grep -Fq "TeamIdentifier=$EXPECTED_TEAM"
    echo "$details" | /usr/bin/grep -Fq "Authority=$EXPECTED_AUTHORITY"
    if echo "$details" | /usr/bin/grep -Eq 'Signature=adhoc|flags=.*adhoc'; then
        echo "ad-hoc signature found: $target" >&2
        return 1
    fi
    if [ "$runtime" = required ]; then
        echo "$details" | /usr/bin/grep -Eq 'flags=.*runtime'
    else
        if echo "$details" | /usr/bin/grep -Eq 'flags=.*runtime'; then
            echo "App unexpectedly has hardened runtime: $target" >&2
            return 1
        fi
    fi
}

assert_signature "$APP" com.deanxi.siriremote forbidden
assert_signature "$DRIVER" com.deanxi.siriremote.audio.driver required
assert_signature "$CAPTURE" SiriRemoteCapture required
assert_signature "$ROUTER" SiriRemoteAudioRouter required
assert_signature "$WATCHDOG" SiriRemoteCoreAudioWatchdog required
assert_signature "$PROCESS_VERIFIER" SiriRemoteProcessVerifier required

/bin/sleep 5 &
verifier_test_pid=$!
if ! "$PROCESS_VERIFIER" "$verifier_test_pid" "$(/usr/bin/id -u)" /bin/sleep; then
    /bin/kill "$verifier_test_pid" 2>/dev/null || true
    wait "$verifier_test_pid" 2>/dev/null || true
    echo "native process identity verification failed" >&2
    exit 1
fi
/bin/kill "$verifier_test_pid" 2>/dev/null || true
wait "$verifier_test_pid" 2>/dev/null || true

# Runtime voice switching must never enable a third-party input method. TISEnableInputSource is an
# onboarding API and causes macOS to display an authorization dialog from the Siri-button path.
APP_SYMBOLS="$(/usr/bin/nm -u "$APP/Contents/MacOS/SiriRemote")"
case "$APP_SYMBOLS" in
    *'_TISEnableInputSource'*)
        echo "App must not enable input sources at runtime" >&2
        exit 1
        ;;
esac
case "$APP_SYMBOLS" in
    *'_TISSelectInputSource'*) ;;
    *) echo "App is missing input-source selection support" >&2; exit 1 ;;
esac

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" \
    = com.deanxi.siriremote ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DRIVER/Contents/Info.plist")" \
    = com.deanxi.siriremote.audio.driver ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$LAUNCHD")" \
    = com.deanxi.siriremote.capture ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCHD")" \
    = "/Library/Application Support/SiriRemote/SiriRemoteCapture" ]

if /usr/bin/find "$PAYLOAD" \
    \( -iname '*PacketLogger*' -o -iname '*HyperVibe*' -o -iname '*SiriRemoteForge*' \
       -o -iname '*remote-mic*' -o -iname '*MiRemoteV*' \) -print | /usr/bin/grep -q .; then
    echo "foreign product content found in package payload" >&2
    exit 1
fi

for package in "$FULL_PKG" "$UNINSTALL_PKG"; do
    signature_output="$AUDIT_DIR/$(basename "$package").signature"
    if /usr/sbin/pkgutil --check-signature "$package" >"$signature_output" 2>&1; then
        echo "PKG unexpectedly carries an Installer signature: $package" >&2
        exit 1
    fi
    /usr/bin/grep -Fq "Status: no signature" "$signature_output"
done

(
    cd "$ROOT/dist/out"
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

echo "package audit: PASS"
