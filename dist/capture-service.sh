#!/bin/bash
# Sourced by the authorized installers. All service targets are fixed, never supplied by a client.
SR_CAPTURE_APP=/Applications/SiriRemote.app
SR_CAPTURE_BINARY="$SR_CAPTURE_APP/Contents/MacOS/SiriRemote"
SR_CAPTURE_PLIST="$SR_CAPTURE_APP/Contents/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist"
SR_CAPTURE_LEGACY_PLIST=/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist
SR_CAPTURE_LEGACY_BINARY="/Library/Application Support/SiriRemote/SiriRemoteCapture"

capture_verify_app() {
    # Check ownership as well as signature before invoking the installed App's fixed registration
    # entry point. The installer never runs code from an unverified or user-writable bundle.
    local path mode details
    for path in "$SR_CAPTURE_APP" "$SR_CAPTURE_APP/Contents" \
        "$SR_CAPTURE_APP/Contents/MacOS" "$SR_CAPTURE_BINARY"; do
        [ ! -L "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" -eq 0 ] || return 1
        mode="$(/usr/bin/stat -f %Lp "$path")"
        [ $((8#$mode & 0022)) -eq 0 ] || return 1
    done
    /usr/bin/codesign --verify --deep --strict \
        -R='anchor apple generic and identifier "com.deanxi.siriremote" and certificate leaf[subject.OU] = "96M7FW2XLU"' \
        "$SR_CAPTURE_APP" || return 1
    # codesign writes metadata in multiple chunks. A grep -q pipe closes early and can give the
    # producer SIGPIPE (141) under pipefail, falsely rejecting a valid signed App during install.
    details="$(/usr/bin/codesign -d --verbose=4 "$SR_CAPTURE_APP" 2>&1)" || return 1
    /usr/bin/grep -Fxq 'Authority=Developer ID Application: ZIAN XI (96M7FW2XLU)' <<< "$details"
}

capture_command() {
    local console_uid
    console_uid="$(/usr/bin/stat -f %u /dev/console)" || return 1
    [ "$console_uid" -gt 0 ] && [ "$console_uid" -ne 65534 ] || {
        echo "Capture registration requires a logged-in console user" >&2
        return 1
    }
    # BTM records and approval UI belong to the login session, not the installer's root session.
    # The service itself still runs as root; SMAppService enforces its own administrator approval.
    /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "#$console_uid" -- \
        "$SR_CAPTURE_BINARY" "$1"
}

capture_stop() {
    local operation="${1:---prepare-capture-update}" status
    case "$operation" in
        --prepare-capture-update|--unregister-capture) ;;
        *) return 1 ;;
    esac
    if [ -f "$SR_CAPTURE_PLIST" ]; then
        capture_verify_app || return 1
        status="$(capture_command --capture-service-status)" || return 1
        case "$status" in
            SIRIREMOTE_CAPTURE_NOT_FOUND|SIRIREMOTE_CAPTURE_NOT_REGISTERED) ;;
            SIRIREMOTE_CAPTURE_ENABLED|SIRIREMOTE_CAPTURE_REQUIRES_APPROVAL)
                capture_command "$operation" || return 1 ;;
            *) echo "Unexpected Capture status before shutdown" >&2; return 1 ;;
        esac
    fi
    if [ -e "$SR_CAPTURE_LEGACY_PLIST" ]; then
        /bin/launchctl bootout system "$SR_CAPTURE_LEGACY_PLIST" 2>/dev/null || true
    fi
    # Neither launchctl bootout nor SMAppService's completion guarantees that the old PID is gone.
    # Do not replace / start a second Capture while the old daemon is still cleaning up a session.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        /usr/bin/pgrep -x SiriRemoteCapture >/dev/null 2>&1 || return 0
        /usr/bin/perl -e 'select(undef, undef, undef, 0.25)'
    done
    echo "SiriRemote Capture did not stop; refusing replacement" >&2
    return 1
}

capture_remove_legacy() {
    # Call only after capture_stop succeeded and a protected rollback copy exists.
    /bin/rm -f "$SR_CAPTURE_LEGACY_PLIST" "$SR_CAPTURE_LEGACY_BINARY"
}

capture_start() {
    local result
    capture_verify_app || return 1
    result="$(capture_command --register-capture)" || return 1
    echo "$result"
    case "$result" in
        SIRIREMOTE_CAPTURE_REQUIRES_APPROVAL)
            # This is a successful installation, not a running service. Keep the user's decision;
            # the App exposes the system approval link only while approval is actually needed.
            echo "Allow SiriRemote in System Settings > General > Login Items & Extensions."
            return 0
            ;;
        SIRIREMOTE_CAPTURE_ENABLED) ;;
        *) echo "Unexpected Capture registration result" >&2; return 1 ;;
    esac
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
        [ ! -f /private/var/run/com.deanxi.siriremote/capture-service-ready ] || return 0
        /usr/bin/perl -e 'select(undef, undef, undef, 0.5)'
    done
    echo "SiriRemote Capture service did not become ready" >&2
    return 1
}
