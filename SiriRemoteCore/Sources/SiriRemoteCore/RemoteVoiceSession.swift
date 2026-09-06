import Foundation


/// Deterministic arbitration for the physical Siri button.
///
/// A short press emits Return as soon as it is released. A physical hold owns one normal voice
/// down/up pair. The A2854 stops producing microphone frames when its physical Siri button is
/// released, so this state machine deliberately has no software-latched recording mode.
public struct SiriButtonGestureMachine: Sendable {
    /// Shared by short-tap classification and production voice activation.
    public static let holdThreshold: TimeInterval = 0.3

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
        // Use the same floating-point boundary tolerance as voice activation.
        return duration + 1e-9 < holdThreshold ? [.endVoice, .sendReturn] : [.endVoice]
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
