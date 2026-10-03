/// A held keyboard/media button emits one down, zero or more repeat-downs, and exactly one up.
/// The platform adapter translates repeatDown into the OS's autorepeat bit.
public enum HeldButtonEdge: Equatable {
    case down, repeatDown, up

    public var isDown: Bool { self != .up }
    public var isRepeat: Bool { self == .repeatDown }
}

/// Tracks only successfully posted downs, so cancellation never releases an unrelated key and a
/// delayed timer cannot synthesize a repeat after teardown. OS event posting remains injectable.
public final class HeldButtonOutput {
    public private(set) var heldButtons: Set<FixedRemoteButton> = []
    private let post: (FixedRemoteButton, HeldButtonEdge) -> Bool

    public init(post: @escaping (FixedRemoteButton, HeldButtonEdge) -> Bool) {
        self.post = post
    }

    @discardableResult
    public func begin(_ button: FixedRemoteButton) -> Bool {
        guard !heldButtons.contains(button) else { return true }
        guard post(button, .down) else { return false }
        heldButtons.insert(button)
        return true
    }

    @discardableResult
    public func repeatDown(_ button: FixedRemoteButton) -> Bool {
        guard heldButtons.contains(button) else { return false }
        return post(button, .repeatDown)
    }

    @discardableResult
    public func end(_ button: FixedRemoteButton) -> Bool {
        guard heldButtons.remove(button) != nil else { return true }
        return post(button, .up)
    }

    public func releaseAll() {
        for button in FixedRemoteButton.allCases where heldButtons.contains(button) {
            _ = end(button)
        }
    }
}
