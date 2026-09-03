import AppKit
import ApplicationServices
import Darwin
import IOKit.hid

enum DoubaoInputSourceStatus: Equatable {
    case notInstalled
    case disabled
    case enabled
}

struct SystemReadinessSnapshot: Equatable {
    let accessibilityGranted: Bool
    /// Effective access to the A2854 HID interfaces. Accessibility already grants event-listening
    /// access, so this is a runtime capability check rather than a separate user permission.
    let hidInputAvailable: Bool
    let driverInstalled: Bool
    let captureServiceStatus: InstalledServiceStatus
    let packetLoggerInstalled: Bool
    let doubaoInputSourceStatus: DoubaoInputSourceStatus

    var corePermissionsGranted: Bool { accessibilityGranted }
    var doubaoInputSourceEnabled: Bool { doubaoInputSourceStatus == .enabled }
}

enum SystemReadiness {
    private static let captureServiceNotification =
        "com.deanxi.siriremote.capture-service"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver"
    static let supportPath = "/Library/Application Support/SiriRemote"
    static let capturePlistPath = "/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist"
    static let packetLoggerPath =
        "/Applications/PacketLogger.app/Contents/Resources/packetlogger"

    private static let captureServiceToken: Int32 = {
        var token: Int32 = -1
        guard notify_register_check(captureServiceNotification, &token) == NOTIFY_STATUS_OK else {
            return -1
        }
        return token
    }()

    static func snapshot() -> SystemReadinessSnapshot {
        let fm = FileManager.default
        let captureComponentsInstalled =
            fm.isExecutableFile(atPath: supportPath + "/SiriRemoteCapture")
            && fm.isExecutableFile(atPath: supportPath + "/SiriRemoteAudioRouter")
            && fm.fileExists(atPath: capturePlistPath)
        let captureStatus = InstalledServiceHealth.resolve(
            componentsInstalled: captureComponentsInstalled,
            advertisedPID: captureServicePID(),
            isProcessAlive: processIsAlive
        )
        let doubao = DoubaoInputSourceCoordinator()
        let doubaoStatus: DoubaoInputSourceStatus
        if doubao.isAvailable {
            doubaoStatus = .enabled
        } else if doubao.isInstalled {
            doubaoStatus = .disabled
        } else {
            doubaoStatus = .notInstalled
        }

        return SystemReadinessSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            hidInputAvailable: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                == kIOHIDAccessTypeGranted,
            driverInstalled: fm.fileExists(atPath: driverPath),
            captureServiceStatus: captureStatus,
            packetLoggerInstalled: fm.isExecutableFile(atPath: packetLoggerPath),
            doubaoInputSourceStatus: doubaoStatus
        )
    }

    private static func captureServicePID() -> Int32? {
        guard captureServiceToken >= 0 else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(captureServiceToken, &state) == NOTIFY_STATUS_OK,
              state > 0, state <= UInt64(Int32.max) else { return nil }
        return Int32(state)
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        errno = 0
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        // The service runs as root. EPERM proves that the PID exists even though this user process
        // is not allowed to signal it.
        return errno == EPERM
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }

    static func openBluetoothSettings() {
        openSystemSettingsPane(bluetoothSettingsPaneIdentifier())
    }

    static func openPacketLoggerDownload() {
        if let url = URL(string: "https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openKeyboardSettings() {
        openSystemSettingsPane("com.apple.Keyboard-Settings.extension")
    }

    static func openDoubaoDownload() {
        if let url = URL(string: "https://srf.doubao.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        openSystemSettings(url)
    }

    private static func bluetoothSettingsPaneIdentifier() -> String {
        // Apple has changed the Bluetooth settings extension identifier between macOS releases.
        // Read the identifier from the installed extension instead of relying on a stale constant.
        let extensionPaths = [
            "/System/Library/ExtensionKit/Extensions/Bluetooth.appex",
            "/System/Library/ExtensionKit/Extensions/BluetoothSettings.appex"
        ]
        for path in extensionPaths {
            if let identifier = Bundle(path: path)?.bundleIdentifier {
                return identifier
            }
        }
        return "com.apple.BluetoothSettings"
    }

    private static func openSystemSettingsPane(_ identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
        openSystemSettings(url)
    }

    private static func openSystemSettings(_ url: URL) {
        // Explicitly target System Settings. Opening the x-apple URL through its default handler
        // can merely activate an already-running Settings window without navigating to the pane.
        guard let settingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: settingsURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
