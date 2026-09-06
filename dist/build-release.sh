#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
VERSION="${1:-0.2.1}"
BUILD_NUMBER="${SIRIREMOTE_BUILD_NUMBER:-5}"
APP_STAGE="$ROOT/dist/build/staging/SiriRemote.app"
RELEASE_SIGN_IDENTITY="Developer ID Application: ZIAN XI (96M7FW2XLU)"
INSTALLER_SIGN_IDENTITY="Developer ID Installer: ZIAN XI (96M7FW2XLU)"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    echo "usage: dist/build-release.sh [numeric-version]" >&2
    exit 2
}

security find-identity -v -p codesigning | grep -Fq "\"$RELEASE_SIGN_IDENTITY\"" || {
    echo "required release signing identity is unavailable: $RELEASE_SIGN_IDENTITY" >&2
    exit 1
}
/usr/bin/security find-identity -v -p basic | /usr/bin/grep -Fq \
    "\"$INSTALLER_SIGN_IDENTITY\"" || {
    echo "required Installer signing identity is unavailable: $INSTALLER_SIGN_IDENTITY" >&2
    exit 1
}
export SIRIREMOTE_SIGN_IDENTITY="$RELEASE_SIGN_IDENTITY"
export SIRIREMOTE_INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY"
export SIRIREMOTE_CODESIGN_TIMESTAMP=secure

(cd SiriRemoteCore && swift test)
(cd app && ./build.sh)
(
    cd app
    SIRIREMOTE_VERSION="$VERSION" \
    SIRIREMOTE_BUILD_NUMBER="$BUILD_NUMBER" \
    SIRIREMOTE_APP_BUNDLE_PATH="$APP_STAGE" \
        ./create_app_bundle.sh
)
(cd mic && ./build-test.sh)
(cd mic/router && ./build.sh)
(
    cd mic/driver
    SIRIREMOTE_VERSION="$VERSION" SIRIREMOTE_BUILD_NUMBER="$BUILD_NUMBER" ./build.sh
)
(cd mic/captured && ./build.sh)

SIRIREMOTE_APP_PATH="$APP_STAGE" dist/package.sh "$VERSION"
dist/audit-package.sh "$VERSION"
echo "✓ SiriRemote local release build complete"
