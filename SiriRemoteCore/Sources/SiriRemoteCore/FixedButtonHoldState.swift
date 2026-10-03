import Foundation

/// Siri deliberately stays outside the ordinary-button repeat engine.
public enum FixedRemoteButton: String, CaseIterable, Hashable, Sendable {
    case power, menu, tv, select
    case ringUp, ringDown, ringLeft, ringRight
    case playPause, mute, volumeUp, volumeDown

    public var activatesOnRelease: Bool {
        switch self {
        case .power, .select, .playPause, .mute: return true
        default: return false
        }
    }

    public var repeatsWhileHeld: Bool {
        switch self {
        case .menu, .ringUp, .ringDown, .ringLeft, .ringRight, .volumeUp, .volumeDown:
            return true
        case .power, .tv, .select, .playPause, .mute:
            return false
        }
    }

    public var hasNativeMediaEvent: Bool {
        switch self {
        case .playPause, .mute, .volumeUp, .volumeDown: return true
        default: return false
        }
    }
}

/// Values come from NSEvent.keyRepeatDelay / keyRepeatInterval in the platform adapter.
/// Invalid or disabled timing means no repeats, not a fallback to a hard-coded fast rate.
public struct ButtonRepeatTiming: Equatable {
    public let delay: TimeInterval
    public let interval: TimeInterval

    public init?(delay: TimeInterval, interval: TimeInterval) {
        guard delay.isFinite, interval.isFinite, delay >= 0, interval > 0 else { return nil }
        self.delay = delay
        self.interval = interval
    }
}

/// Owns a physical hold and produces explicit begin/repeat/end commands. Repeats are down events
/// with the autorepeat bit, never repeated taps. Release-only actions are cancelled on teardown.
public struct FixedButtonHoldState {
    public enum Command: Equatable {
        case beginHold(FixedRemoteButton)
        case repeatHold(FixedRemoteButton)
        case endHold(FixedRemoteButton)
        case activate(FixedRemoteButton)
    }

    private static let mediaReleaseTail: TimeInterval = 0.3

    public private(set) var heldButtons: Set<FixedRemoteButton> = []
    private var repeatDeadlines: [FixedRemoteButton: TimeInterval] = [:]
    private var repeatIntervals: [FixedRemoteButton: TimeInterval] = [:]
    private var mediaReleaseDeadlines: [FixedRemoteButton: TimeInterval] = [:]

    public init() {}

    public var nextRepeatAt: TimeInterval? { repeatDeadlines.values.min() }

    public mutating func press(
        _ button: FixedRemoteButton, at time: TimeInterval, timing: ButtonRepeatTiming?
    ) -> [Command] {
        guard heldButtons.insert(button).inserted else { return [] }
        mediaReleaseDeadlines[button] = nil
        if button.repeatsWhileHeld, let timing {
            repeatDeadlines[button] = time + timing.delay
            repeatIntervals[button] = timing.interval
        }
        return button.activatesOnRelease ? [] : [.beginHold(button)]
    }

    @discardableResult
    public mutating func release(
        _ button: FixedRemoteButton, at time: TimeInterval, cancelled: Bool = false
    ) -> [Command] {
        guard heldButtons.remove(button) != nil else { return [] }
        consumeUntilRelease(button)
        if button.hasNativeMediaEvent {
            mediaReleaseDeadlines[button] = time + Self.mediaReleaseTail
        }
        if button.activatesOnRelease { return cancelled ? [] : [.activate(button)] }
        return [.endHold(button)]
    }

    /// A volume press consumed by a voice chord must never start changing volume after Siri-up.
    public mutating func consumeUntilRelease(_ button: FixedRemoteButton) {
        repeatDeadlines[button] = nil
        repeatIntervals[button] = nil
    }

    public mutating func takeRepeats(at time: TimeInterval) -> [Command] {
        var due: [Command] = []
        for button in FixedRemoteButton.allCases {
            guard let deadline = repeatDeadlines[button], let interval = repeatIntervals[button],
                  time + 1e-9 >= deadline else { continue }
            due.append(.repeatHold(button))
            // No catch-up burst after a busy main loop or a suspended process.
            repeatDeadlines[button] = time + interval
        }
        return due
    }

    public func suppressesNativeMedia(_ button: FixedRemoteButton, at time: TimeInterval) -> Bool {
        guard button.hasNativeMediaEvent else { return false }
        return heldButtons.contains(button) || time < (mediaReleaseDeadlines[button] ?? -.infinity)
    }

    @discardableResult
    public mutating func reset() -> [Command] {
        let releases = FixedRemoteButton.allCases.filter {
            heldButtons.contains($0) && !$0.activatesOnRelease
        }.map { Command.endHold($0) }
        heldButtons.removeAll()
        repeatDeadlines.removeAll()
        repeatIntervals.removeAll()
        mediaReleaseDeadlines.removeAll()
        return releases
    }
}
