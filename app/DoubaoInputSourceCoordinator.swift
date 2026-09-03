import AppKit
import Carbon
import Foundation

/// Selects an already-enabled Doubao input source and leaves it selected after the voice session.
final class DoubaoInputSourceCoordinator {
    private static let targetID = "com.bytedance.inputmethod.doubaoime.pinyin"
    private static let bundleID = "com.bytedance.inputmethod.doubaoime"
    private static let thirdPartySourcesDomain = "com.apple.inputsources" as CFString
    private static let thirdPartySourcesKey = "AppleEnabledThirdPartyInputSources" as CFString
    private static let legacySourcesDomain = "com.apple.HIToolbox" as CFString
    private static let legacySourcesKey = "AppleEnabledInputSources" as CFString
    static let enabledSourcesDidChangeNotification = Notification.Name(
        rawValue: kTISNotifyEnabledKeyboardInputSourcesChanged as String
    )

    /// Voice sessions may select only sources the user has already enabled in System Settings.
    /// Calling TISEnableInputSource from a Siri-button event makes macOS display a security prompt
    /// asking whether SiriRemote may enable the third-party input method.
    var isAvailable: Bool {
        Self.isConfiguredAsEnabled
            && Self.inputSource(withID: Self.targetID, includeAllInstalled: false) != nil
    }
    var isInstalled: Bool {
        Self.inputSource(withID: Self.targetID, includeAllInstalled: true) != nil
    }
    var isSelected: Bool { Self.currentInputSourceID() == Self.targetID }
    var currentSourceID: String? { Self.currentInputSourceID() }

    @discardableResult
    func selectDoubao() -> Bool {
        guard Self.isConfiguredAsEnabled else { return false }
        if isSelected { return true }
        guard let source = Self.inputSource(
            withID: Self.targetID, includeAllInstalled: false
        ) else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    private static func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(kTISPropertyInputSourceID, from: source)
    }

    private static func inputSource(withID targetID: String,
                                    includeAllInstalled: Bool) -> TISInputSource? {
        let values = TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as NSArray
        for object in values {
            let source = object as! TISInputSource
            if stringProperty(kTISPropertyInputSourceID, from: source) == targetID { return source }
        }
        return nil
    }

    private static var isConfiguredAsEnabled: Bool {
        // TIS can keep the currently selected third-party source marked as enabled after the user
        // removes it from Keyboard settings. macOS 26 stores the authoritative third-party list
        // in com.apple.inputsources; older releases used the HIToolbox enabled-source list.
        if let entries = enabledSourceEntries(
            key: thirdPartySourcesKey,
            domain: thirdPartySourcesDomain
        ) {
            return containsDoubao(entries)
        }
        guard let entries = enabledSourceEntries(
            key: legacySourcesKey,
            domain: legacySourcesDomain
        ) else { return false }
        return containsDoubao(entries)
    }

    private static func enabledSourceEntries(key: CFString,
                                             domain: CFString) -> [[String: Any]]? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(
            key,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [[String: Any]]
    }

    private static func containsDoubao(_ entries: [[String: Any]]) -> Bool {
        return entries.contains { entry in
            (entry["Input Mode"] as? String) == targetID
                || (entry["Bundle ID"] as? String) == bundleID
        }
    }

    private static func stringProperty(_ key: CFString, from source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }
}
