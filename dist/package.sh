#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export COPYFILE_DISABLE=1

ROOT="$PWD"
VERSION="${1:-0.2.1}"
APP_SOURCE="${SIRIREMOTE_APP_PATH:-$ROOT/app/SiriRemote.app}"
OUTPUT_NAME="${SIRIREMOTE_PACKAGE_OUTPUT_NAME:-out}"
[[ "$OUTPUT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || exit 2
OUT="$ROOT/dist/$OUTPUT_NAME"
WORK="$ROOT/dist/build/package"
FULL_ROOT="$WORK/full-root"
FULL_SCRIPTS="$WORK/full-scripts"
UNINSTALL_SCRIPTS="$WORK/uninstall-scripts"
COMPONENTS_PLIST="$WORK/full-components.plist"
RELEASE_PREFIX="SiriRemote-$VERSION"
FULL_NAME="$RELEASE_PREFIX-Full-Setup.pkg"
UNINSTALL_NAME="$RELEASE_PREFIX-Complete-Uninstall.pkg"
CHECKSUM_NAME="$RELEASE_PREFIX-SHA256SUMS.txt"
FULL_PKG="$OUT/$FULL_NAME"
UNINSTALL_PKG="$OUT/$UNINSTALL_NAME"
FULL_UNSIGNED_PKG="$WORK/$RELEASE_PREFIX-Full-Setup-unsigned.pkg"
UNINSTALL_UNSIGNED_PKG="$WORK/$RELEASE_PREFIX-Complete-Uninstall-unsigned.pkg"
MACOS_MIN="${SIRIREMOTE_MACOS_MIN:-13.0}"
INSTALLER_HELPER_SIGN_IDENTITY="${SIRIREMOTE_SIGN_IDENTITY:-Developer ID Application: ZIAN XI (96M7FW2XLU)}"
INSTALLER_SIGN_IDENTITY="${SIRIREMOTE_INSTALLER_SIGN_IDENTITY:-Developer ID Installer: ZIAN XI (96M7FW2XLU)}"
CODE_SIGN_TIMESTAMP="${SIRIREMOTE_CODESIGN_TIMESTAMP:-none}"

case "$CODE_SIGN_TIMESTAMP" in
    none) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none) ;;
    secure) CODE_SIGN_TIMESTAMP_ARGS=(--timestamp) ;;
    *)
        echo "SIRIREMOTE_CODESIGN_TIMESTAMP must be 'none' or 'secure'" >&2
        exit 2
        ;;
esac

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
/usr/bin/security find-identity -v -p basic \
    | /usr/bin/grep -Fq "\"$INSTALLER_SIGN_IDENTITY\"" || {
    echo "required Installer signing identity is unavailable: $INSTALLER_SIGN_IDENTITY" >&2
    exit 1
}

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
/usr/bin/codesign --force --options runtime "${CODE_SIGN_TIMESTAMP_ARGS[@]}" \
    --sign "$INSTALLER_HELPER_SIGN_IDENTITY" "$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog"
/usr/bin/codesign --force --options runtime "${CODE_SIGN_TIMESTAMP_ARGS[@]}" \
    --sign "$INSTALLER_HELPER_SIGN_IDENTITY" "$FULL_SCRIPTS/SiriRemoteProcessVerifier"
xcrun clang -O2 -Wall -Wextra -Werror "$ROOT/dist/shm_cleanup.c" \
    -o "$UNINSTALL_SCRIPTS/SiriRemoteShmCleanup"
/bin/chmod 755 "$FULL_SCRIPTS/preinstall" "$FULL_SCRIPTS/postinstall" \
    "$FULL_SCRIPTS/SiriRemoteCoreAudioWatchdog" "$FULL_SCRIPTS/SiriRemoteProcessVerifier" \
    "$UNINSTALL_SCRIPTS/postinstall" "$UNINSTALL_SCRIPTS/SiriRemoteShmCleanup"

/usr/bin/pkgbuild --root "$FULL_ROOT" --scripts "$FULL_SCRIPTS" \
    --component-plist "$COMPONENTS_PLIST" \
    --identifier com.deanxi.siriremote.full --version "$VERSION" \
    --install-location / --ownership recommended "$FULL_UNSIGNED_PKG"
/usr/bin/pkgbuild --nopayload --scripts "$UNINSTALL_SCRIPTS" \
    --identifier com.deanxi.siriremote.uninstall --version "$VERSION" "$UNINSTALL_UNSIGNED_PKG"

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

repack_without_appledouble "$FULL_UNSIGNED_PKG" "$FULL_ROOT"
repack_without_appledouble "$UNINSTALL_UNSIGNED_PKG"

/usr/sbin/pkgutil --expand-full "$FULL_UNSIGNED_PKG" "$WORK/full-expanded"
/usr/sbin/pkgutil --expand-full "$UNINSTALL_UNSIGNED_PKG" "$WORK/uninstall-expanded"
[ -f "$WORK/full-expanded/Scripts/preinstall" ]
[ -f "$WORK/full-expanded/Scripts/postinstall" ]
[ -f "$WORK/uninstall-expanded/Scripts/postinstall" ]
[ -z "$(/usr/bin/find "$WORK/full-expanded" "$WORK/uninstall-expanded" -name '._*' -print -quit)" ]

/usr/bin/productsign --sign "$INSTALLER_SIGN_IDENTITY" --timestamp \
    "$FULL_UNSIGNED_PKG" "$FULL_PKG"
/usr/bin/productsign --sign "$INSTALLER_SIGN_IDENTITY" --timestamp \
    "$UNINSTALL_UNSIGNED_PKG" "$UNINSTALL_PKG"
/usr/sbin/pkgutil --check-signature "$FULL_PKG"
/usr/sbin/pkgutil --check-signature "$UNINSTALL_PKG"

(
    cd "$OUT"
    /usr/bin/shasum -a 256 "$FULL_NAME" "$UNINSTALL_NAME"
) > "$OUT/$CHECKSUM_NAME"

echo "✓ $FULL_PKG"
echo "✓ $UNINSTALL_PKG"
echo "✓ $OUT/$CHECKSUM_NAME"
echo "✓ PKG signed with $INSTALLER_SIGN_IDENTITY"
echo "⚠ PKG has not been notarized or stapled."
