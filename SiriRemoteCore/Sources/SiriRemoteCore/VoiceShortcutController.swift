import Foundation

/// Serializes recognizer gestures on the App's existing 20 ms voice poll. No sleeping, detached
/// tasks or uncancellable delayed key-ups. Typeless uses 120 ms start chords and plain Fn stops;
/// Doubao holds Right Command. A new session cannot overtake the previous stop tap.
@MainActor
public final class VoiceShortcutController {
    public enum Phase: Equatable { case idle, held, startingTap, recording, stoppingTap }
    public private(set) var phase: Phase = .idle
    public var isBusy: Bool { phase != .idle || pending != nil }
    public static let tapDuration: TimeInterval = 0.12

    private struct Request {
        let session: UInt64
        let shortcut: VoiceShortcut
    }
    private let setShortcut: (VoiceShortcut, Bool) -> Bool
    private let onStarted: (UInt64, Bool) -> Void
    private let onStopFailure: () -> Void
    private var current: Request?
    private var pending: Request?
    private var releaseAt: TimeInterval = 0
    private var endedDuringStart = false
    private var downShortcut: VoiceShortcut?

    public init(setShortcut: @escaping (VoiceShortcut, Bool) -> Bool,
                onStarted: @escaping (UInt64, Bool) -> Void,
                onStopFailure: @escaping () -> Void) {
        self.setShortcut = setShortcut
        self.onStarted = onStarted
        self.onStopFailure = onStopFailure
    }

    public func start(session: UInt64, target: VoiceTarget, mode: TypelessVoiceMode = .dictate,
                      at now: TimeInterval) {
        guard current?.session != session, pending?.session != session else { return }
        let request = Request(session: session, shortcut: VoiceShortcut(target: target, mode: mode))
        if isBusy {
            // The voice lifecycle owns at most one following session. Never replace an existing
            // pending request silently or let an overlapping start toggle the recognizer off.
            guard pending == nil, phase == .stoppingTap else {
                onStarted(session, false)
                return
            }
            pending = request
            return
        }
        begin(request, at: now)
    }

    public func end(session: UInt64, at now: TimeInterval) {
        if pending?.session == session {
            pending = nil
            onStarted(session, false)
        }
        guard let current, current.session == session else { return }
        switch phase {
        case .held:
            let success = releaseKey()
            finish(at: now, allowNext: success)
            if !success { onStopFailure() }
        case .startingTap:
            endedDuringStart = true
        case .recording:
            beginStop(current, at: now)
        case .stoppingTap, .idle:
            break
        }
    }

    public func poll(at now: TimeInterval) {
        guard let request = current, now + 1e-9 >= releaseAt else { return }
        switch phase {
        case .startingTap:
            guard releaseKey() else {
                finish(at: now, allowNext: false)
                onStarted(request.session, false)
                return
            }
            phase = .recording
            onStarted(request.session, true)
            // onStarted may synchronously end/abort this generation.
            if current?.session == request.session, phase == .recording, endedDuringStart {
                beginStop(request, at: now)
            }
        case .stoppingTap:
            let success = releaseKey()
            finish(at: now, allowNext: success)
            if !success { onStopFailure() }
        case .idle, .held, .recording:
            break
        }
    }

    public func cancelAll(at now: TimeInterval) {
        pending = nil
        if let current { end(session: current.session, at: now) }
    }

    /// Termination cannot depend on another run-loop tick. Complete an in-flight tap, then send
    /// a stop only if we owned a started toggle session. Never toggle again during a stop tap.
    public func shutdown() {
        pending = nil
        guard let current else { return }
        let needsStop = current.shortcut.target == .typeless
            && (phase == .startingTap || phase == .recording)
        var success = releaseKey()
        if needsStop {
            if setShortcut(current.shortcut.stopShortcut, true) {
                success = setShortcut(current.shortcut.stopShortcut, false) && success
            } else { success = false }
        }
        self.current = nil
        phase = .idle
        endedDuringStart = false
        if !success { onStopFailure() }
    }

    private func begin(_ request: Request, at now: TimeInterval) {
        current = request
        endedDuringStart = false
        guard setShortcut(request.shortcut, true) else {
            current = nil
            phase = .idle
            onStarted(request.session, false)
            return
        }
        downShortcut = request.shortcut
        if request.shortcut.target == .doubao {
            phase = .held
            onStarted(request.session, true)
        } else {
            phase = .startingTap
            releaseAt = now + Self.tapDuration
        }
    }

    private func beginStop(_ request: Request, at now: TimeInterval) {
        guard setShortcut(request.shortcut.stopShortcut, true) else {
            finish(at: now, allowNext: false)
            onStopFailure()
            return
        }
        downShortcut = request.shortcut.stopShortcut
        phase = .stoppingTap
        releaseAt = now + Self.tapDuration
    }

    private func releaseKey() -> Bool {
        guard let owned = downShortcut else { return true }
        downShortcut = nil
        return setShortcut(owned, false)
    }

    private func finish(at now: TimeInterval, allowNext: Bool) {
        current = nil
        phase = .idle
        endedDuringStart = false
        if let next = pending {
            pending = nil
            // A failed stop leaves the external toggle state unknown. Do not let a queued
            // start silently toggle that same recording again (or leak a shortcut into another app).
            if allowNext { begin(next, at: now) }
            else { onStarted(next.session, false) }
        }
    }
}
