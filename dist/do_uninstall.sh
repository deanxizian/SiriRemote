#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "SiriRemote uninstaller must run as root" >&2; exit 1; }

APP="/Applications/SiriRemote.app"
DRIVER="/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver"
SUPPORT="/Library/Application Support/SiriRemote"
PLIST="/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist"
LOG_DIR="/Library/Logs/SiriRemote"
RUNTIME_DIR="/private/var/run/com.deanxi.siriremote"
DEBUG_DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debug"
DEBUG_PLIST="${DEBUG_DOMAIN}.plist"
DEBUG_BACKUP="$SUPPORT/preinstall-HCITraces.plist"
DEBUG_ABSENT="$SUPPORT/preinstall-HCITraces.absent"

/usr/bin/killall SiriRemote 2>/dev/null || true
/bin/launchctl bootout system "$PLIST" 2>/dev/null || true

if [ -f "$DEBUG_BACKUP" ]; then
    /usr/bin/defaults delete "$DEBUG_DOMAIN" HCITraces 2>/dev/null || true
    [ -f "$DEBUG_PLIST" ] || /usr/bin/plutil -create binary1 "$DEBUG_PLIST"
    hci_xml="$(/bin/cat "$DEBUG_BACKUP")"
    /usr/bin/plutil -insert HCITraces -xml "$hci_xml" "$DEBUG_PLIST"
elif [ -f "$DEBUG_ABSENT" ]; then
    /usr/bin/defaults delete "$DEBUG_DOMAIN" HCITraces 2>/dev/null || true
fi

/bin/rm -f "$PLIST"
/bin/rm -rf "$APP" "$DRIVER" "$SUPPORT" "$LOG_DIR" "$RUNTIME_DIR"

console_user="$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
    user_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null \
        | /usr/bin/awk '{print $2}')"
    if [ -n "$user_home" ] && [ -d "$user_home/Library" ]; then
        /bin/rm -rf "$user_home/Library/Application Support/SiriRemote"
        /bin/rm -rf "$user_home/Library/Logs/SiriRemote"
        /bin/rm -rf "$user_home/Library/Caches/com.deanxi.siriremote"
        /bin/rm -rf "$user_home/Library/Saved Application State/com.deanxi.siriremote.savedState"
        /bin/rm -f "$user_home/Library/Preferences/com.deanxi.siriremote.plist"
        if [ -d "$user_home/Library/Preferences/ByHost" ]; then
            /usr/bin/find "$user_home/Library/Preferences/ByHost" -maxdepth 1 -type f \
                -name 'com.deanxi.siriremote.*.plist' -delete
        fi
    fi
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ ! -x "$script_dir/SiriRemoteShmCleanup" ] || "$script_dir/SiriRemoteShmCleanup" || true
/usr/bin/killall coreaudiod 2>/dev/null || true
/usr/bin/killall -30 bluetoothd 2>/dev/null || true
/usr/sbin/pkgutil --forget com.deanxi.siriremote.full >/dev/null 2>&1 || true

echo "SiriRemote 已完整卸载；PacketLogger 和其他项目组件未被修改。"
exit 0
