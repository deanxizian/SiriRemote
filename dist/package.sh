#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1

ROOT="$PWD"
VERSION="${1:-0.1.0}"
APP_SOURCE="${SIRIREMOTE_APP_PATH:-$ROOT/app/SiriRemote.app}"
OUT="$ROOT/dist/out"
WORK="$ROOT/dist/build/package"
FULL_ROOT="$WORK/full-root"
FULL_SCRIPTS="$WORK/full-scripts"
UNINSTALL_SCRIPTS="$WORK/uninstall-scripts"
COMPONENTS_PLIST="$WORK/full-components.plist"
FULL_PKG="$OUT/SiriRemote-Full-Setup.pkg"
UNINSTALL_PKG="$OUT/SiriRemote-Complete-Uninstall.pkg"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
INSTALLER_HELPER_SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    echo "package version must be numeric: $VERSION" >&2
    exit 2
}

need() { [ -e "$1" ] || { echo "missing build artifact: $1" >&2; exit 1; }; }
need "$APP_SOURCE"
need "$ROOT/mic/driver/SiriRemoteAudio.driver"
need "$ROOT/mic/router/SiriRemoteAudioRouter"
need "$ROOT/mic/captured/SiriRemoteCapture"
need "$ROOT/mic/captured/com.deanxi.siriremote.capture.plist"

/bin/rm -rf "$WORK" "$OUT"
/bin/mkdir -p "$FULL_ROOT/Applications" \
    "$FULL_ROOT/Library/Audio/Plug-Ins/HAL" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/Legal" \
    "$FULL_ROOT/Library/LaunchDaemons" \
    "$FULL_ROOT/Library/Logs/SiriRemote" \
    "$FULL_SCRIPTS" "$UNINSTALL_SCRIPTS" "$OUT"

/usr/bin/ditto "$APP_SOURCE" "$FULL_ROOT/Applications/SiriRemote.app"
/usr/bin/ditto "$ROOT/mic/driver/SiriRemoteAudio.driver" \
    "$FULL_ROOT/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver"
/bin/cp "$ROOT/mic/router/SiriRemoteAudioRouter" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/SiriRemoteAudioRouter"
/bin/cp "$ROOT/mic/captured/SiriRemoteCapture" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/SiriRemoteCapture"
/bin/cp "$ROOT/mic/captured/com.deanxi.siriremote.capture.plist" \
    "$FULL_ROOT/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist"
/bin/cp "$ROOT/LICENSE" "$FULL_ROOT/Library/Application Support/SiriRemote/Legal/GPL-3.0.txt"
/bin/cp "$ROOT/NOTICE" "$FULL_ROOT/Library/Application Support/SiriRemote/Legal/NOTICE.txt"
/bin/cp "$ROOT/SOURCE_PROVENANCE.md" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/Legal/SOURCE_PROVENANCE.md"
/bin/cp "$ROOT/mic/driver/vendor/BlackHole-LICENSE.txt" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/Legal/BlackHole-LICENSE.txt"
/bin/cp "$ROOT/mic/router/Opus-LICENSE.txt" \
    "$FULL_ROOT/Library/Application Support/SiriRemote/Legal/Opus-LICENSE.txt"

# PackageKit otherwise serializes Finder/provenance xattrs as AppleDouble `._*` payload files.
# They are not product content and are not part of any code signature.
/usr/bin/xattr -cr "$FULL_ROOT"

# pkgbuild marks application bundles as relocatable by default. PackageKit can then use an
# existing development copy with the same bundle identifier as the install destination (for
# example, App/SiriRemote.app inside this checkout) instead of /Applications/SiriRemote.app.
# That both violates the product layout and makes postinstall fail. Generate the component list
# from the actual payload and explicitly pin every discovered bundle to its root-relative path.
/usr/bin/pkgbuild --analyze --root "$FULL_ROOT" "$COMPONENTS_PLIST"
component_index=0
while /usr/libexec/PlistBuddy -c "Print :$component_index" "$COMPONENTS_PLIST" \
    >/dev/null 2>&1; do
    if /usr/libexec/PlistBuddy -c "Print :$component_index:BundleIsRelocatable" \
        "$COMPONENTS_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$component_index:BundleIsRelocatable false" \
            "$COMPONENTS_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :$component_index:BundleIsRelocatable bool false" \
            "$COMPONENTS_PLIST"
    fi
    component_index=$((component_index + 1))
done
[ "$component_index" -gt 0 ] || {
    echo "pkgbuild did not discover any bundle components" >&2
    exit 1
}

/bin/cp "$ROOT/dist/pkg/preinstall" "$FULL_SCRIPTS/preinstall"
/bin/cp "$ROOT/dist/pkg/postinstall" "$FULL_SCRIPTS/postinstall"
/bin/cp "$ROOT/dist/do_uninstall.sh" "$UNINSTALL_SCRIPTS/postinstall"
xcrun clang -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min="$MACOS_MIN" "$ROOT/dist/coreaudio_watchdog.c" \
    -o "$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog"
xcrun clang -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min="$MACOS_MIN" "$ROOT/dist/process_verifier.c" \
    -o "$FULL_SCRIPTS/SiriRemoteProcessVerifier"
"$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog" --self-test
/usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$INSTALLER_HELPER_SIGN_IDENTITY" "$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog"
/usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$INSTALLER_HELPER_SIGN_IDENTITY" "$FULL_SCRIPTS/SiriRemoteProcessVerifier"
xcrun clang -O2 -Wall -Wextra -Werror "$ROOT/dist/shm_cleanup.c" \
    -o "$UNINSTALL_SCRIPTS/SiriRemoteShmCleanup"
/bin/chmod 755 "$FULL_SCRIPTS/preinstall" "$FULL_SCRIPTS/postinstall" \
    "$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog" "$FULL_SCRIPTS/SiriRemoteProcessVerifier" \
    "$UNINSTALL_SCRIPTS/postinstall" "$UNINSTALL_SCRIPTS/SiriRemoteShmCleanup"

/usr/bin/pkgbuild --root "$FULL_ROOT" --scripts "$FULL_SCRIPTS" \
    --component-plist "$COMPONENTS_PLIST" \
    --identifier com.deanxi.siriremote.full --version "$VERSION" \
    --install-location / --ownership recommended "$FULL_PKG"
/usr/bin/pkgbuild --nopayload --scripts "$UNINSTALL_SCRIPTS" \
    --identifier com.deanxi.siriremote.uninstall --version "$VERSION" "$UNINSTALL_PKG"

# macOS 26 attaches a protected com.apple.provenance xattr even to locally-created files. pkgbuild
# serializes that metadata as zero-byte `._*` AppleDouble entries despite COPYFILE_DISABLE. Repack
# the generated package with a portable cpio payload and metadata-free script archive so those
# implementation artifacts never reach the installed filesystem.
repack_without_appledouble() {
    package="$1"
    payload_root="${2:-}"
    stem="$(/usr/bin/basename "$package" .pkg)"
    expanded="$WORK/repack-$stem"
    cleaned="$WORK/$stem-clean.pkg"
    original="$WORK/$stem-metadata-original.pkg"

    /usr/sbin/pkgutil --expand "$package" "$expanded"
    if [ -d "$expanded/Scripts" ]; then
        /usr/bin/find "$expanded/Scripts" -name '._*' -delete
    fi
    if [ -n "$payload_root" ]; then
        /bin/mv "$expanded/Payload" "$expanded/Payload.metadata-original"
        (
            cd "$payload_root"
            /usr/bin/find . -print0 \
                | /usr/bin/cpio -o -0 -z --format odc -R root:wheel --quiet
        ) > "$expanded/Payload"
        /usr/bin/mkbom "$payload_root" "$expanded/Bom"
        payload_count="$(/usr/bin/lsbom -s "$expanded/Bom" | /usr/bin/awk 'END { print NR }')"
        /usr/bin/sed -E -i '' \
            "s/(<payload numberOfFiles=\")[0-9]+/\\1$payload_count/" \
            "$expanded/PackageInfo"
        /bin/mv "$expanded/Payload.metadata-original" "$WORK/$stem-Payload.metadata-original"
    fi
    /usr/sbin/pkgutil --flatten "$expanded" "$cleaned"
    /bin/mv "$package" "$original"
    /bin/mv "$cleaned" "$package"
}

repack_without_appledouble "$FULL_PKG" "$FULL_ROOT"
repack_without_appledouble "$UNINSTALL_PKG"

/usr/sbin/pkgutil --expand-full "$FULL_PKG" "$WORK/full-expanded"
/usr/sbin/pkgutil --expand-full "$UNINSTALL_PKG" "$WORK/uninstall-expanded"
[ -f "$WORK/full-expanded/Scripts/preinstall" ]
[ -f "$WORK/full-expanded/Scripts/postinstall" ]
[ -f "$WORK/uninstall-expanded/Scripts/postinstall" ]
[ -z "$(/usr/bin/find "$WORK/full-expanded" "$WORK/uninstall-expanded" -name '._*' -print -quit)" ]

(
    cd "$OUT"
    /usr/bin/shasum -a 256 SiriRemote-Full-Setup.pkg SiriRemote-Complete-Uninstall.pkg
) > "$OUT/SHA256SUMS.txt"

echo "✓ $FULL_PKG"
echo "✓ $UNINSTALL_PKG"
echo "⚠ PKG 未签名：本机安装可用，但尚未公证，不用于公开分发。"
