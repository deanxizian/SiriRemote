#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-run}"
APP_NAME="SiriRemote"
BUNDLE_ID="com.deanxi.siriremote"
STABLE_SIGN_IDENTITY="Developer ID Application: ZIAN XI (96M7FW2XLU)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="$ROOT_DIR/dist/local"
STAGE_APP="$STAGE_DIR/SiriRemote.app"
LIVE_APP="/Applications/SiriRemote.app"
LIVE_BINARY="$LIVE_APP/Contents/MacOS/SiriRemote"
LIVE_INFO="$LIVE_APP/Contents/Info.plist"
PROCESS_VERIFIER=""

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

identity_available() {
    /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -Fq "\"$STABLE_SIGN_IDENTITY\""
}

signature_info() {
    /usr/bin/codesign -d --verbose=4 "$1" 2>&1
}

verify_local_bundle() {
    bundle="$1"
    /usr/bin/codesign --verify --strict --verbose=2 "$bundle"
    info="$(signature_info "$bundle")"
    echo "$info" | /usr/bin/grep -Fq "Identifier=$BUNDLE_ID"
    echo "$info" | /usr/bin/grep -Fq "Authority=$STABLE_SIGN_IDENTITY"
    if echo "$info" | /usr/bin/grep -Eq 'Signature=adhoc|flags=.*adhoc'; then
        echo "refusing ad-hoc-signed bundle: $bundle" >&2
        return 1
    fi
}

verify_single_live_process() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pids="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)"
        count="$(echo "$pids" | /usr/bin/awk 'NF { count++ } END { print count+0 }')"
        if [ "$count" -eq 1 ] \
            && "$PROCESS_VERIFIER" "$pids" "$(/usr/bin/id -u)" "$LIVE_BINARY"; then
            echo "✓ one live SiriRemote process: $LIVE_BINARY"
            return 0
        fi
        /usr/bin/perl -e 'select(undef, undef, undef, 0.25)'
    done
    echo "SiriRemote did not start as exactly one process from $LIVE_BINARY" >&2
    return 1
}

if ! identity_available; then
    echo "required stable signing identity is unavailable: $STABLE_SIGN_IDENTITY" >&2
    echo "the installed App was not stopped or replaced" >&2
    exit 1
fi

# PackageKit compares the incoming App bundle version with the installed one. Reusing the source
# template's 0.1.0 (1) can report a successful package transaction while leaving a newer live App
# untouched. Keep the installed marketing version and advance only the local build number so every
# verified development build is an actual upgrade.
LOCAL_VERSION="${SIRIREMOTE_VERSION:-0.1.0}"
LOCAL_BUILD_NUMBER="${SIRIREMOTE_BUILD_NUMBER:-1}"
if [ -f "$LIVE_INFO" ]; then
    if [ -z "${SIRIREMOTE_VERSION:-}" ]; then
        LOCAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$LIVE_INFO")"
    fi
    if [ -z "${SIRIREMOTE_BUILD_NUMBER:-}" ]; then
        installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$LIVE_INFO")"
        case "$installed_build" in
            ''|*[!0-9]*) echo "invalid installed SiriRemote build number: $installed_build" >&2; exit 1 ;;
        esac
        LOCAL_BUILD_NUMBER="$((installed_build + 1))"
    fi
fi

(cd "$ROOT_DIR/SiriRemoteCore" && /usr/bin/swift test)
(cd "$ROOT_DIR/app" && ./build.sh)
/bin/mkdir -p "$STAGE_DIR"
(
    cd "$ROOT_DIR/app"
    SIRIREMOTE_SIGN_IDENTITY="$STABLE_SIGN_IDENTITY" \
    SIRIREMOTE_VERSION="$LOCAL_VERSION" \
    SIRIREMOTE_BUILD_NUMBER="$LOCAL_BUILD_NUMBER" \
    SIRIREMOTE_APP_BUNDLE_PATH="$STAGE_APP" \
        ./create_app_bundle.sh
)
verify_local_bundle "$STAGE_APP"

# A Full Setup install owns /Applications/SiriRemote.app as root and macOS App Management blocks a
# direct user-space rename even for an admin account. Install the already verified App through a
# one-component package so Authorization Services and Installer perform the replacement atomically.
# The old process remains alive unless and until installation succeeds.
INSTALL_WORK="$(/usr/bin/mktemp -d /private/tmp/siriremote-install.XXXXXX)"
INSTALL_PKG="$INSTALL_WORK/SiriRemote.pkg"
PROCESS_VERIFIER="$INSTALL_WORK/SiriRemoteProcessVerifier"

cleanup_install_work() {
    /bin/rm -f "$INSTALL_PKG" "$PROCESS_VERIFIER" >/dev/null 2>&1 || true
    /bin/rmdir "$INSTALL_WORK" >/dev/null 2>&1 || true
}
trap cleanup_install_work EXIT INT TERM HUP

xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT_DIR/dist/process_verifier.c" -o "$PROCESS_VERIFIER"
/usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$STABLE_SIGN_IDENTITY" "$PROCESS_VERIFIER"
/usr/bin/codesign --verify --strict "$PROCESS_VERIFIER"
verifier_info="$(signature_info "$PROCESS_VERIFIER")"
echo "$verifier_info" | /usr/bin/grep -Fq 'Identifier=SiriRemoteProcessVerifier'
echo "$verifier_info" | /usr/bin/grep -Fq "Authority=$STABLE_SIGN_IDENTITY"

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$STAGE_APP/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$STAGE_APP/Contents/Info.plist")"
COPYFILE_DISABLE=1 /usr/bin/pkgbuild \
    --component "$STAGE_APP" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID.local-update" \
    --version "$app_version.$app_build" \
    "$INSTALL_PKG" >/dev/null

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    /usr/sbin/installer -pkg "$INSTALL_PKG" -target /
else
    # INSTALL_WORK is generated by mktemp from a fixed template and cannot contain shell syntax.
    /usr/bin/osascript -e \
        "do shell script \"/usr/sbin/installer -pkg $INSTALL_PKG -target /\" with administrator privileges"
fi
verify_local_bundle "$LIVE_APP"

# Restart only after Installer has committed and the installed signature has been verified.
/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8; do
    /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    /usr/bin/perl -e 'select(undef, undef, undef, 0.25)'
done
/usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1 && {
    echo "could not stop the existing SiriRemote process" >&2
    false
}

open_live_app() {
    /usr/bin/open -n "$LIVE_APP" --args --settings
}

case "$MODE" in
    --debug|debug)
        cleanup_install_work
        trap - EXIT INT TERM HUP
        exec /usr/bin/lldb -- "$LIVE_BINARY" --settings
        ;;
    --logs|logs)
        open_live_app
        verify_single_live_process
        cleanup_install_work
        trap - EXIT INT TERM HUP
        exec /usr/bin/log stream --info --style compact --predicate 'process == "SiriRemote"'
        ;;
    --telemetry|telemetry)
        open_live_app
        verify_single_live_process
        cleanup_install_work
        trap - EXIT INT TERM HUP
        exec /usr/bin/log stream --info --style compact \
            --predicate 'process == "SiriRemote" OR subsystem == "com.deanxi.siriremote"'
        ;;
    run|--verify|verify)
        open_live_app
        verify_single_live_process
        ;;
esac

cleanup_install_work
trap - EXIT INT TERM HUP
echo "✓ installed and launched $LIVE_APP"
