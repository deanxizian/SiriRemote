import Foundation

/// The production PTT lifecycle. Time, audio counters and OS side-effect results are inputs, so
/// the same code used by the App can be tested without emitting a key or opening a microphone.
public struct DoubaoVoiceSession {
    public enum Phase: Equatable { case idle, priming, active, draining }
    public enum Command: Equatable {
        case beginCapture(UInt64), endCapture(UInt64), seal(UInt64, UInt64)
        case selectInputSource(UInt64), pressFn(UInt64), releaseFn
        case failure(String)
    }
    public struct Audio: Equatable {
        public var available: Bool
        public var generation: UInt64
        public var write: UInt64
        public var read: UInt64
        public var active: Bool
        public var consumers: UInt32
        public init(available: Bool = false, generation: UInt64 = 0, write: UInt64 = 0,
                    read: UInt64 = 0, active: Bool = false, consumers: UInt32 = 0) {
            self.available = available; self.generation = generation
            self.write = write; self.read = read; self.active = active; self.consumers = consumers
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var session: UInt64 = 0
    public private(set) var pendingPressAt: TimeInterval?
    private var pressedAt: TimeInterval?
    private var preparationDeadline: TimeInterval = 0
    private var audioGeneration: UInt64?
    private var lastAudio = Audio()
    private var lastAdvanceAt: TimeInterval = 0
    private var selectionRequested = false
    private var sourceReadyAt: TimeInterval?
    private var fnRequested = false
    private var fnHeld = false
    private var releasedAt: TimeInterval?
    private var finalWrite: UInt64?
    private var drainDeadline: TimeInterval = 0

    public init() {}

    public mutating func press(at now: TimeInterval) -> [Command] {
        if phase == .draining {
            guard pendingPressAt == nil else { return [] }
            pendingPressAt = now
            // Freeze the OLD audio range before a second physical press can add its frames.
            // A pending press starts only after the old Fn is up and the old lease is released.
            return sealIfNeeded(at: now)
        }
        guard phase == .idle else { return [] }
        return start(at: now, physicalPressAt: now)
    }

    private mutating func start(at now: TimeInterval, physicalPressAt: TimeInterval) -> [Command] {
        session &+= 1
        if session == 0 { session = 1 }
        phase = .priming
        pressedAt = physicalPressAt
        preparationDeadline = now + 1.5
        audioGeneration = nil
        lastAudio = Audio()
        lastAdvanceAt = now
        selectionRequested = false
        sourceReadyAt = nil
        fnRequested = false
        fnHeld = false
        releasedAt = nil
        finalWrite = nil
        return [.beginCapture(session)]
    }

    public mutating func release(at now: TimeInterval) -> [Command] {
        if pendingPressAt != nil { pendingPressAt = nil; return [] }
        guard let started = pressedAt else { return [] }
        pressedAt = nil
        if now - started + 1e-9 < SiriButtonGestureMachine.holdThreshold {
            return abort(reason: nil)
        }
        releasedAt = now
        if phase == .active { phase = .draining }
        else if phase == .priming && !selectionRequested { return abort(reason: nil) }
        return []
    }

    public mutating func inputSourceSelected(session candidate: UInt64, at now: TimeInterval,
                                            success: Bool, settleDelay: TimeInterval) -> [Command] {
        guard candidate == session, phase == .priming, selectionRequested else { return [] }
        guard success else { return abort(reason: "无法切换到豆包输入法") }
        sourceReadyAt = now + settleDelay
        return []
    }

    public mutating func fnResult(session candidate: UInt64, at now: TimeInterval,
                                 success: Bool) -> [Command] {
        guard candidate == session, phase == .priming, fnRequested else {
            // A stale completion must never release a newer session's held Fn.
            return success && !fnHeld ? [.releaseFn] : []
        }
        guard success else { return abort(reason: "Fn 发送失败，请检查辅助功能权限") }
        fnHeld = true
        lastAdvanceAt = now
        phase = releasedAt == nil ? .active : .draining
        return []
    }

    public mutating func poll(_ audio: Audio, at now: TimeInterval) -> [Command] {
        guard phase != .idle else { return [] }
        if let expected = audioGeneration,
           !audio.available || audio.generation != expected || !audio.active {
            return abort(reason: "遥控器音频会话已中断")
        }
        if audio.write != lastAudio.write || audio.generation != lastAudio.generation {
            lastAdvanceAt = now
        }
        lastAudio = audio
        switch phase {
        case .priming:
            if now >= preparationDeadline { return abort(reason: "1.5 秒内没有收到遥控器音频") }
            if let ready = sourceReadyAt, now >= ready, !fnRequested {
                fnRequested = true
                return [.pressFn(session)]
            }
            if !selectionRequested, let pressedAt,
               now - pressedAt + 1e-9 >= SiriButtonGestureMachine.holdThreshold,
               audio.available, audio.active, audio.write > 0 {
                audioGeneration = audio.generation
                selectionRequested = true
                return [.selectInputSource(session)]
            }
        case .active:
            if now - lastAdvanceAt >= 0.3 { return abort(reason: "遥控器音频采集已中断") }
        case .draining:
            guard let released = releasedAt else { return [] }
            var commands: [Command] = []
            if finalWrite == nil && (now - max(released, lastAdvanceAt) >= 0.08 ||
                                    now - released >= 0.3) {
                commands += sealIfNeeded(at: now)
            }
            if let end = finalWrite,
               (audio.consumers > 0 && audio.read >= end) || now >= drainDeadline {
                commands += finish(at: now)
            }
            return commands
        case .idle: break
        }
        return []
    }

    private mutating func sealIfNeeded(at now: TimeInterval) -> [Command] {
        guard finalWrite == nil else { return [] }
        finalWrite = lastAudio.write
        drainDeadline = now + 0.75
        return [.seal(session, lastAudio.write)]
    }

    private mutating func finish(at now: TimeInterval) -> [Command] {
        var commands: [Command] = fnHeld ? [.releaseFn] : []
        commands.append(.endCapture(session))
        fnHeld = false
        phase = .idle
        if let pending = pendingPressAt {
            pendingPressAt = nil
            commands += start(at: now, physicalPressAt: pending)
        }
        return commands
    }

    public mutating func abort(reason: String?) -> [Command] {
        var commands: [Command] = fnHeld ? [.releaseFn] : []
        if phase != .idle { commands.append(.endCapture(session)) }
        session &+= 1 // invalidates delayed input-source/Fn completions
        phase = .idle
        pressedAt = nil
        pendingPressAt = nil
        fnHeld = false
        audioGeneration = nil
        if let reason { commands.append(.failure(reason)) }
        return commands
    }
}
