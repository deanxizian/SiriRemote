#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/siriremote-service-test.XXXXXX)"
trap '/bin/rm -rf "$WORK"' EXIT
TRACE="$WORK/trace"
MOCK_READY_PATH="$WORK/ready"

# Exercise the production migration functions with all privileged effects replaced in memory.
# No root, services, system files or Background Task Management records are touched.
source_text="$(<"$ROOT_DIR/dist/capture-service.sh")"
source_text="${source_text//\/bin\/launchctl/fake_launchctl}"
source_text="${source_text//\/usr\/bin\/pgrep/fake_pgrep}"
source_text="${source_text//\/usr\/bin\/perl/fake_pause}"
source_text="${source_text//\/bin\/rm/fake_rm}"
source_text="${source_text//\"\$SR_CAPTURE_BINARY\"/fake_app}"
source_text="${source_text//\/private\/var\/run\/com.deanxi.siriremote\/capture-service-ready/\$MOCK_READY_PATH}"
eval "$source_text"
SR_CAPTURE_PLIST="$WORK/bundled.plist"
SR_CAPTURE_LEGACY_PLIST="$WORK/legacy.plist"
SR_CAPTURE_LEGACY_BINARY="$WORK/legacy-binary"

capture_verify_app() { "$trusted"; }
capture_command() { fake_app "$1"; }
fake_app() { printf '%s\n' "$1" >> "$TRACE"; echo "$registration"; "$command_succeeds"; }
fake_launchctl() { printf '%s\n' "$*" >> "$TRACE"; }
fake_pgrep() { "$process_running"; }
fake_pause() { printf 'wait\n' >> "$TRACE"; }
fake_rm() { printf 'remove:%s\n' "$*" >> "$TRACE"; }
reset_case() {
    : > "$TRACE"
    /bin/rm -f "$SR_CAPTURE_PLIST" "$SR_CAPTURE_LEGACY_PLIST" "$MOCK_READY_PATH"
    trusted=true command_succeeds=true process_running=false
    registration=SIRIREMOTE_CAPTURE_ENABLED
}

reset_case
touch "$SR_CAPTURE_LEGACY_PLIST"
capture_stop
grep -Fxq "bootout system $SR_CAPTURE_LEGACY_PLIST" "$TRACE"
! grep -q -- '--.*capture' "$TRACE"

reset_case
touch "$SR_CAPTURE_PLIST"
capture_stop
grep -Fxq -- '--prepare-capture-update' "$TRACE"
! grep -q bootout "$TRACE"
: > "$TRACE"
capture_stop --unregister-capture
grep -Fxq -- '--unregister-capture' "$TRACE"

for registration in SIRIREMOTE_CAPTURE_NOT_FOUND SIRIREMOTE_CAPTURE_NOT_REGISTERED; do
    : > "$TRACE"
    capture_stop
    grep -Fxq -- '--capture-service-status' "$TRACE"
    ! grep -Eq -- '--prepare-capture-update|--unregister-capture' "$TRACE"
done
registration=UNEXPECTED
! capture_stop

reset_case
touch "$SR_CAPTURE_PLIST"
trusted=false
! capture_stop
[ ! -s "$TRACE" ]
! capture_start
[ ! -s "$TRACE" ]

reset_case
touch "$SR_CAPTURE_PLIST"
command_succeeds=false
! capture_stop
! grep -q remove "$TRACE"

reset_case
process_running=true
! capture_stop
[ "$(grep -c '^wait$' "$TRACE")" -eq 20 ]
! grep -q remove "$TRACE"

reset_case
registration=SIRIREMOTE_CAPTURE_REQUIRES_APPROVAL
capture_start
[ "$(grep -c -- '--register-capture' "$TRACE")" -eq 1 ]
! grep -q wait "$TRACE"

reset_case
touch "$MOCK_READY_PATH"
capture_start
[ "$(grep -c -- '--register-capture' "$TRACE")" -eq 1 ]
! grep -q wait "$TRACE"

reset_case
! capture_start
[ "$(grep -c '^wait$' "$TRACE")" -eq 24 ]

reset_case
registration=SIRIREMOTE_CAPTURE_NOT_FOUND
! capture_start
! grep -q wait "$TRACE"

reset_case
capture_remove_legacy
grep -Fxq "remove:-f $SR_CAPTURE_LEGACY_PLIST $SR_CAPTURE_LEGACY_BINARY" "$TRACE"

# The root installer must enter the logged-in user's bootstrap and Unix identity. It must not
# register against root's unrelated BTM context, or guess a user when no one is logged in.
command_source="$(sed -n '/^capture_command() {$/,/^}$/p' "$ROOT_DIR/dist/capture-service.sh")"
command_source="${command_source/capture_command()/exercise_console_command()}"
command_source="${command_source//\/usr\/bin\/stat/fake_console_stat}"
command_source="${command_source//\/bin\/launchctl/fake_console_launchctl}"
eval "$command_source"
fake_console_stat() { [ "$*" = '-f %u /dev/console' ] && echo "$console_uid_value"; }
fake_console_launchctl() {
    [ "$#" -eq 9 ] && [ "$1" = asuser ] && [ "$2" = 501 ] \
        && [ "$3" = /usr/bin/sudo ] && [ "$4" = -H ] && [ "$5" = -u ] \
        && [ "$6" = '#501' ] && [ "$7" = -- ] \
        && [ "$8" = "$SR_CAPTURE_BINARY" ] && [ "$9" = --register-capture ]
}
console_uid_value=501
exercise_console_command --register-capture
console_uid_value=0
! exercise_console_command --register-capture
console_uid_value=65534
! exercise_console_command --register-capture

# Regress the real signature-check function with chunked metadata output. A live `codesign |
# grep -q` pipeline returned SIGPIPE under the installer's pipefail even for a valid identity.
verification_source="$(sed -n '/^capture_verify_app() {$/,/^}$/p' "$ROOT_DIR/dist/capture-service.sh")"
verification_source="${verification_source/capture_verify_app()/exercise_signature_verifier()}"
verification_source="${verification_source//\/usr\/bin\/codesign/fake_codesign}"
verification_source="${verification_source//\/usr\/bin\/stat/fake_stat}"
eval "$verification_source"
SR_CAPTURE_APP="$WORK/SiriRemote.app"
SR_CAPTURE_BINARY="$SR_CAPTURE_APP/Contents/MacOS/SiriRemote"
mkdir -p "$SR_CAPTURE_APP/Contents/MacOS"
touch "$SR_CAPTURE_BINARY"
signature_valid=true
component_mode=755
signature_authority='Developer ID Application: ZIAN XI (96M7FW2XLU)'
fake_stat() {
    case "$2" in
        %u) echo 0 ;;
        %Lp) echo "$component_mode" ;;
        *) return 1 ;;
    esac
}
fake_codesign() {
    if [ "$1" = --verify ]; then "$signature_valid"; return; fi
    printf 'Authority=%s\n' "$signature_authority"
    for ((chunk=0; chunk<4096; chunk++)); do
        printf 'Signature metadata emitted after the authority line\n'
    done
}
exercise_signature_verifier
signature_valid=false
! exercise_signature_verifier
signature_valid=true
signature_authority='untrusted'
! exercise_signature_verifier
signature_authority='Developer ID Application: ZIAN XI (96M7FW2XLU)'
component_mode=777
! exercise_signature_verifier

echo 'Capture migration, approval, stop bounds and fixed cleanup targets: PASS'
