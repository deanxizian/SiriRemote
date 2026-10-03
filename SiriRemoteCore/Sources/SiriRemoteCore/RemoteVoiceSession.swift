import Foundation


/// Deterministic arbitration for the physical Siri button.
///
/// A single short press emits Return after the double-tap window. Two short presses switch the
/// selected voice app, without Return or latched recording. A physical hold still owns one normal
/// voice down/up pair; A2854 stops microphone frames when its physical Siri button is released.
public struct SiriButtonGestureMachine: Sendable {
    /// Shared by short-tap classification and production voice activation.
    public static let holdThreshold: TimeInterval = 0.3
    public static let doubleTapInterval: TimeInterval = 0.3

    public enum Command: Equatable, Sendable {
        case beginVoice
        case endVoice
        case sendReturn
        case switchVoiceTarget
    }

    private var pressedAt: TimeInterval?
    private var usedVoiceChord = false
    private var isSecondTap = false
    public private(set) var pendingTapDeadline: TimeInterval?

    public init() {}

    public var isPhysicallyPressed: Bool { pressedAt != nil }

    public mutating func press(at time: TimeInterval) -> [Command] {
        guard pressedAt == nil else { return [] }
        // Flush a single tap whose deadline passed even if its run-loop timer was delayed. A
        // second press before the deadline consumes it immediately, including when that second
        // press later turns into a voice hold rather than a short double-tap.
        let expired = poll(at: time)
        isSecondTap = pendingTapDeadline != nil
        pendingTapDeadline = nil
        pressedAt = time
        usedVoiceChord = false
        return expired + [.beginVoice]
    }

    public mutating func release(
        at time: TimeInterval,
        holdThreshold: TimeInterval
    ) -> [Command] {
        guard let startedAt = pressedAt else { return [] }
        pressedAt = nil
        let duration = max(0, time - startedAt)
        let shortTap = !usedVoiceChord && duration + 1e-9 < holdThreshold
        let shouldSwitch = shortTap && isSecondTap
        if shortTap && !isSecondTap {
            pendingTapDeadline = time + Self.doubleTapInterval
        }
        isSecondTap = false
        usedVoiceChord = false
        // Use the same floating-point boundary tolerance as voice activation.
        return shouldSwitch ? [.endVoice, .switchVoiceTarget] : [.endVoice]
    }

    public mutating func poll(at time: TimeInterval) -> [Command] {
        guard let deadline = pendingTapDeadline, time + 1e-9 >= deadline else { return [] }
        pendingTapDeadline = nil
        return [.sendReturn]
    }

    /// Returns nil when the volume key must keep its ordinary system action. A used chord also
    /// consumes a short Siri release, so an aborted mode selection cannot accidentally send text.
    public mutating func consumeVoiceChord(
        _ button: VoiceVolumeButton, target: VoiceTarget
    ) -> TypelessVoiceMode? {
        guard target == .typeless, isPhysicallyPressed else { return nil }
        usedVoiceChord = true
        return button == .up ? .translate : .askAnything
    }

    /// Voice capture may be pre-warmed on down, but a shortcut may only start after the same physical
    /// press reaches the hold threshold.
    public func canActivateVoice(at time: TimeInterval, holdThreshold: TimeInterval) -> Bool {
        guard let startedAt = pressedAt else { return false }
        return time - startedAt + 1e-9 >= holdThreshold
    }

    /// A failed pre-warm does not change gesture classification: a short physical press must still
    /// become Return, while a held press must remain a failed voice attempt rather than a tap.
    public mutating func voiceSessionFailed() {}

    /// Invalidates the physical gesture during disconnect, sleep, permission loss or teardown. The
    /// voice coordinator separately owns the guaranteed demand and shortcut release.
    public mutating func cancelAll() -> [Command] {
        pressedAt = nil
        usedVoiceChord = false
        isSecondTap = false
        pendingTapDeadline = nil
        return []
    }
}
