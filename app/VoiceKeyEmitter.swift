import ApplicationServices
import Foundation

/// Platform adapter for Doubao's Right Command and Typeless's mode chords. Ownership and timing live in
/// VoiceKeyLatch and VoiceShortcutController; this adapter only constructs and posts one edge.
enum VoiceKeyEmitter {
    private static let syntheticMarker: Int64 = 0x53524D46 // SRMF

    static func post(_ edge: VoiceKeyEvent) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: edge.key.keyCode,
                keyDown: edge.isDown
              ) else {
            rmDebug("🎙 unable to construct synthetic \(edge.key) \(edge.isDown ? "down" : "up")")
            return false
        }
        event.flags = CGEventFlags(rawValue: edge.flags)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
        return true
    }
}
