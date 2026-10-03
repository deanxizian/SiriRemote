public struct VoiceKeyEvent: Equatable, Sendable {
    public let key: VoiceTriggerKey
    public let isDown: Bool
    public let flags: UInt64
}

/// Owns only successfully posted edges. Chord releases run in reverse order with the remaining
/// modifier flags; failed partial presses are rolled back without leaking Space or held modifiers.
@MainActor
public final class VoiceKeyLatch {
    public private(set) var heldShortcut: VoiceShortcut?
    public private(set) var heldKeys: [VoiceTriggerKey] = []
    private let post: (VoiceKeyEvent) -> Bool

    public init(post: @escaping (VoiceKeyEvent) -> Bool) {
        self.post = post
    }

    @discardableResult
    public func press(_ shortcut: VoiceShortcut) -> Bool {
        if let heldShortcut { return heldShortcut == shortcut }
        heldShortcut = shortcut
        for key in shortcut.keys {
            let flags = heldFlags | key.downFlagsRawValue
            guard post(VoiceKeyEvent(key: key, isDown: true, flags: flags)) else {
                release()
                return false
            }
            heldKeys.append(key)
        }
        return true
    }

    @discardableResult
    public func release() -> Bool {
        var success = true
        while let key = heldKeys.popLast() {
            // Always attempt every owned release, even if an earlier edge failed.
            if !post(VoiceKeyEvent(key: key, isDown: false, flags: heldFlags)) { success = false }
        }
        heldShortcut = nil
        return success
    }

    private var heldFlags: UInt64 { heldKeys.reduce(0) { $0 | $1.downFlagsRawValue } }
}
