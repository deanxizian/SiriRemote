import Foundation

/// Pure timing/generation gate used by the real Doubao PTT coordinator. It owns the physical Siri
/// hold lifetime, so delayed callbacks from an older session cannot promote or finish a newer one.
public struct RemoteVoiceSessionGate: Sendable {
    public enum Release: Equatable, Sendable {
        case stale
        case quickTap(duration: TimeInterval)
        case held(duration: TimeInterval)
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var pressedAt: TimeInterval?

    public init() {}

    public var isPressed: Bool { pressedAt != nil }

    @discardableResult
    public mutating func begin(at time: TimeInterval) -> UInt64? {
        guard pressedAt == nil else { return nil }
        generation &+= 1
        pressedAt = time
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    public func canPromote(
        generation candidate: UInt64,
        at time: TimeInterval,
        minimumHold: TimeInterval,
        audioReady: Bool
    ) -> Bool {
        guard candidate == generation, let pressedAt, audioReady else { return false }
        // Monotonic timestamps can lose a few ulps when a large base value is subtracted. Treat
        // the exact configured boundary as eligible while keeping materially shorter taps out.
        return time - pressedAt + 1e-9 >= minimumHold
    }

    public mutating func release(
        generation candidate: UInt64,
        at time: TimeInterval,
        quickTapThreshold: TimeInterval
    ) -> Release {
        guard candidate == generation, let pressedAt else { return .stale }
        self.pressedAt = nil
        let duration = max(0, time - pressedAt)
        return duration < quickTapThreshold
            ? .quickTap(duration: duration)
            : .held(duration: duration)
    }

    /// Invalidates timers, input-source callbacks and drain completions belonging to the old hold.
    @discardableResult
    public mutating func invalidate() -> UInt64 {
        generation &+= 1
        pressedAt = nil
        return generation
    }
}

/// Deterministic arbitration for the physical Siri button.
///
/// A short press emits Return as soon as it is released. A physical hold owns one normal voice
/// down/up pair. The A2854 stops producing microphone frames when its physical Siri button is
/// released, so this state machine deliberately has no software-latched recording mode.
public struct SiriButtonGestureMachine: Sendable {
    public enum Command: Equatable, Sendable {
        case beginVoice
        case endVoice
        case sendReturn
    }

    private var pressedAt: TimeInterval?

    public init() {}

    public var isPhysicallyPressed: Bool { pressedAt != nil }

    public mutating func press(at time: TimeInterval) -> [Command] {
        guard pressedAt == nil else { return [] }
        pressedAt = time
        return [.beginVoice]
    }

    public mutating func release(
        at time: TimeInterval,
        holdThreshold: TimeInterval
    ) -> [Command] {
        guard let startedAt = pressedAt else { return [] }
        pressedAt = nil
        let duration = max(0, time - startedAt)
        return duration < holdThreshold ? [.endVoice, .sendReturn] : [.endVoice]
    }

    /// Voice capture may be pre-warmed on down, but Fn may only be held after the same physical
    /// press reaches the hold threshold.
    public func canActivateVoice(at time: TimeInterval, holdThreshold: TimeInterval) -> Bool {
        guard let startedAt = pressedAt else { return false }
        return time - startedAt + 1e-9 >= holdThreshold
    }

    /// A failed pre-warm does not change gesture classification: a short physical press must still
    /// become Return, while a held press must remain a failed voice attempt rather than a tap.
    public mutating func voiceSessionFailed() {}

    /// Invalidates the physical gesture during disconnect, sleep, permission loss or teardown. The
    /// voice coordinator separately owns the guaranteed demand and Fn release.
    public mutating func cancelAll() -> [Command] {
        pressedAt = nil
        return []
    }
}
