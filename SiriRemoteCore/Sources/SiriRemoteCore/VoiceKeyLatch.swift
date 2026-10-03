/// Owns a single synthetic modifier. Releases always use the key captured at key-down, even if
/// the selected voice tool changes. The injected sender lets tests exercise this without typing.
@MainActor
public final class VoiceKeyLatch {
    public private(set) var heldKey: VoiceTriggerKey?
    private let post: (VoiceTriggerKey, Bool) -> Bool

    public init(post: @escaping (VoiceTriggerKey, Bool) -> Bool) {
        self.post = post
    }

    @discardableResult
    public func press(_ key: VoiceTriggerKey) -> Bool {
        if let heldKey { return heldKey == key }
        guard post(key, true) else { return false }
        heldKey = key
        return true
    }

    @discardableResult
    public func release() -> Bool {
        guard let heldKey else { return true }
        let posted = post(heldKey, false)
        // A failed synthetic key-up must not leave internal ownership latched forever.
        self.heldKey = nil
        return posted
    }
}
