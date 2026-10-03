import ApplicationServices
import Foundation

/// Platform adapter for Doubao's Right Command and Typeless's Fn. Ownership and timing live in
/// VoiceKeyLatch and VoiceShortcutController; this adapter only constructs and posts one edge.
enum VoiceKeyEmitter {
    private static let syntheticMarker: Int64 = 0x53524D46 // SRMF

    static func post(_ key: VoiceTriggerKey, isDown: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: key.keyCode,
                keyDown: isDown
              ) else {
            rmDebug("🎙 unable to construct synthetic \(key) \(isDown ? "down" : "up")")
            return false
        }
        event.flags = isDown ? CGEventFlags(rawValue: key.downFlagsRawValue) : []
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
        return true
    }
}
