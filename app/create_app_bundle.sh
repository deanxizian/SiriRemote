#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$0")" && /bin/pwd -P)"

APP_BUNDLE="${SIRIREMOTE_APP_BUNDLE_PATH:-SiriRemote.app}"
BINARY_PATH="${SIRIREMOTE_BINARY_PATH:-SiriRemote}"
APP_VERSION="${SIRIREMOTE_VERSION:-0.2.1}"
BUILD_NUMBER="${SIRIREMOTE_BUILD_NUMBER:-5}"
SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
CODE_SIGN_TIMESTAMP="${SIRIREMOTE_CODESIGN_TIMESTAMP:-none}"

case "$CODE_SIGN_TIMESTAMP" in
    none) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none) ;;
    secure) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp) ;;
    *)
        echo "SIRIREMOTE_CODESIGN_TIMESTAMP must be 'none' or 'secure'" >&2
        exit 2
        ;;
esac

[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    echo "invalid SIRIREMOTE_VERSION: $APP_VERSION" >&2
    exit 2
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
    echo "invalid SIRIREMOTE_BUILD_NUMBER: $BUILD_NUMBER" >&2
    exit 2
}
[ -x "$BINARY_PATH" ] || { echo "missing App executable: $BINARY_PATH" >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\"" || {
    echo "required signing identity is unavailable: $SIGN_IDENTITY" >&2
    exit 1
}

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Licenses"
/bin/cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/SiriRemote"
/bin/cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP_BUNDLE/Contents/Info.plist"

if [ ! -f SiriRemote.icns ]; then
    ICON_WORK="$(mktemp -d)"
    trap '/bin/rm -rf "$ICON_WORK"' EXIT
    if swift tools/make_app_icon.swift "$ICON_WORK/SiriRemote.iconset" >/dev/null \
        && iconutil -c icns "$ICON_WORK/SiriRemote.iconset" -o SiriRemote.icns; then
        echo "✓ generated SiriRemote icon"
    else
        echo "warning: app icon generation failed" >&2
    fi
fi
[ ! -f SiriRemote.icns ] || /bin/cp SiriRemote.icns "$APP_BUNDLE/Contents/Resources/SiriRemote.icns"

/bin/cp ../LICENSE "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
/bin/cp ../NOTICE "$APP_BUNDLE/Contents/Resources/NOTICE.txt"
/bin/cp ../SOURCE_PROVENANCE.md "$APP_BUNDLE/Contents/Resources/SOURCE_PROVENANCE.md"
/bin/cp ../mic/driver/vendor/BlackHole-LICENSE.txt \
    "$APP_BUNDLE/Contents/Resources/Licenses/BlackHole-LICENSE.txt"
/bin/cp ../mic/router/Opus-LICENSE.txt \
    "$APP_BUNDLE/Contents/Resources/Licenses/Opus-LICENSE.txt"
for localization in Resources/*.lproj; do
    [ -d "$localization" ] || continue
    /usr/bin/ditto "$localization" \
        "$APP_BUNDLE/Contents/Resources/$(/usr/bin/basename "$localization")"
done

/bin/chmod 755 "$APP_BUNDLE/Contents/MacOS/SiriRemote"
# Deliberately omit --options runtime: MultitouchSupport's private callback is rejected under
# hardened runtime on current macOS. The helper and HAL plug-in remain hardened separately.
codesign --force "${CODE_SIGN_TIMESTAMP_ARGS[@]}" --entitlements SiriRemote.entitlements \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

ACTUAL_ID="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1 \
    | /usr/bin/awk -F= '/^Identifier=/{print $2}')"
[ "$ACTUAL_ID" = "com.deanxi.siriremote" ] || {
    echo "unexpected signed bundle identifier: $ACTUAL_ID" >&2
    exit 1
}
echo "✓ built and signed $APP_BUNDLE"
