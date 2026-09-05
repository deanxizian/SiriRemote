#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
cd "$SCRIPT_DIR"

echo "Building SiriRemote…"

SWIFT_FILES=(
    "main.swift"
    "Localization.swift"
    "ApplicationMenu.swift"
    "SiriRemoteApp.swift"
    "LaunchAtLogin.swift"
    "MenuBarManager.swift"
    "RemoteDetector.swift"
    "RemoteInputHandler.swift"
    "FixedKeyEmitter.swift"
    "DoubaoInputSourceCoordinator.swift"
    "FunctionKeyLatch.swift"
    "AppSwitcherKeyLatch.swift"
    "RemoteAudioDemand.swift"
    "DoubaoVoiceCoordinator.swift"
    "CursorController.swift"
    "MediaController.swift"
    "MediaKeyInterceptor.swift"
    "TouchHandler.swift"
    "SettingsModel.swift"
    "SettingsView.swift"
    "SettingsWindow.swift"
    "SystemReadiness.swift"
    "ConfigStore.swift"
    "ConfigFileWatcher.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/JSONC.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/Config.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/ConfigLoader.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/ConfigWriter.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/InputPolicies.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/ServiceHealth.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/RemoteAggregation.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/RemoteVoiceSession.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/DoubaoVoiceSession.swift"
    "../SiriRemoteCore/Sources/SiriRemoteCore/CircularScroll.swift"
)

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
MODULE_CACHE="/private/tmp/com.deanxi.siriremote-app-module-cache-$ARCH"
mkdir -p "$MODULE_CACHE"
if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx13.0"
else
    TARGET="x86_64-apple-macosx13.0"
fi

clang -c -O2 -Wall -Wextra -Werror \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min=13.0 \
    RemoteAudioState.c \
    -o RemoteAudioState.o

swiftc \
    -O \
    -whole-module-optimization \
    -warnings-as-errors \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -o SiriRemote \
    "${SWIFT_FILES[@]}" \
    RemoteAudioState.o \
    -import-objc-header SiriRemote-Bridging-Header.h \
    -F /System/Library/PrivateFrameworks \
    -framework IOKit \
    -framework CoreGraphics \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework Carbon \
    -framework AppKit \
    -framework ServiceManagement \
    -framework Security \
    -framework SwiftUI \
    -framework MultitouchSupport

APP_SYMBOLS="$(/usr/bin/nm -u SiriRemote)"
case "$APP_SYMBOLS" in
    *'_TISEnableInputSource'*)
        echo "SiriRemote must not enable third-party input sources at runtime" >&2
        exit 1
        ;;
esac
case "$APP_SYMBOLS" in
    *'_TISSelectInputSource'*) ;;
    *) echo "SiriRemote is missing input-source selection support" >&2; exit 1 ;;
esac

echo "✓ app/SiriRemote"
