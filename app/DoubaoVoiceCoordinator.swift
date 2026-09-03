import AppKit
import ApplicationServices
import Foundation

@MainActor
final class DoubaoVoiceCoordinator {
    enum Phase: String, Equatable {
        case idle, priming, active, draining, aborting
    }

    private let inputSource = DoubaoInputSourceCoordinator()
    private let functionKey = FunctionKeyLatch()
    private let demand = RemoteAudioDemand()
    // TISSelectInputSource returns before the foreground text context necessarily observes the
    // new source. This is a one-shot propagation delay, not another source-selection attempt.
    private static let inputSourceApplyDelay: CFTimeInterval = 0.25
    private static let holdThreshold: TimeInterval = 0.2
    private var siriButtonGesture = SiriButtonGestureMachine()
    private var sessionGate = RemoteVoiceSessionGate()
    private var phase: Phase = .idle
    private var selectionInFlight = false
    private var remoteReleasedDuringStart = false
    private var fnHeldForSession = false
    private var releasedAt: CFTimeInterval = 0
    private var baselineGeneration: UInt64 = 0
    private var baselineWriteIndex: UInt64 = 0
    private var lastWriteIndex: UInt64 = 0
    private var lastWriteAdvanceAt: CFTimeInterval = 0
    private var finalWriteIndex: UInt64?
    private var drainDeadline: CFTimeInterval = 0
    private var pollTimer: Timer?
    private var timeoutWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?

    func handleSiri(pressed: Bool) {
        let now = CACurrentMediaTime()
        let commands = pressed
            ? siriButtonGesture.press(at: now)
            : siriButtonGesture.release(
                at: now,
                holdThreshold: Self.holdThreshold
            )
        rmDebug(
            "🎙 Siri \(pressed ? "down" : "up") phase=\(phase.rawValue) "
                + "commands=\(commands)"
        )
        executeSiriButton(commands)
    }

    private func executeSiriButton(_ commands: [SiriButtonGestureMachine.Command]) {
        for command in commands {
            switch command {
            case .beginVoice:
                _ = begin()
            case .endVoice:
                end()
            case .sendReturn:
                rmDebug("🎙 Siri single tap → Return")
                FixedKeyEmitter.tap(.enter)
            }
        }
    }

    private func resetSiriButtonGesture() {
        executeSiriButton(siriButtonGesture.cancelAll())
    }

    @discardableResult
    private func begin() -> Bool {
        if sessionGate.isPressed { return true }
        guard phase == .idle else {
            abortSession(reason: "上一段语音尚未结束", voiceSessionFailed: true)
            return false
        }

        // A completed session must never leave the synthetic Fn modifier held. Repair any stale
        // state before accepting a new physical Siri-button generation.
        if functionKey.isHeld {
            rmDebug("🎙 repairing stale Fn hold before a new Siri session")
            _ = functionKey.release()
        }
        selectionInFlight = false
        remoteReleasedDuringStart = false
        fnHeldForSession = false
        rmDebug("🎙 input source at Siri down=\(inputSource.currentSourceID ?? "unknown")")

        let now = CACurrentMediaTime()
        guard let session = sessionGate.begin(at: now) else {
            siriButtonGesture.voiceSessionFailed()
            return false
        }
        let state = audioState()
        baselineGeneration = state.generation
        baselineWriteIndex = state.writeIndex
        lastWriteIndex = state.writeIndex
        lastWriteAdvanceAt = now
        finalWriteIndex = nil
        drainDeadline = 0

        guard demand.setActive(true) else {
            abortSession(reason: "无法启动遥控器语音采集服务", voiceSessionFailed: true)
            return false
        }
        publish(.priming, "正在准备遥控器麦克风…")
        startPolling(session: session)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGate.isCurrent(session), self.phase == .priming else {
                return
            }
            self.abortSession(
                reason: "1.5 秒内没有收到遥控器音频",
                voiceSessionFailed: true
            )
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
        return true
    }

    private func startPolling(session: UInt64) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionGate.isCurrent(session) else { return }
                self.poll(session: session)
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll(session: UInt64) {
        let now = CACurrentMediaTime()
        let state = audioState()
        if state.writeIndex != lastWriteIndex {
            lastWriteIndex = state.writeIndex
            lastWriteAdvanceAt = now
        }

        switch phase {
        case .priming:
            let moved = (state.generation == baselineGeneration)
                ? state.writeIndex != baselineWriteIndex
                : state.writeIndex > 0
            let audioReady = state.available && state.producerActive && moved
            guard siriButtonGesture.canActivateVoice(
                at: now,
                holdThreshold: Self.holdThreshold
            ), sessionGate.canPromote(
                generation: session, at: now, minimumHold: 0.2, audioReady: audioReady
            ), !selectionInFlight else { return }
            selectionInFlight = true
            guard inputSource.isAvailable else {
                abortSession(
                    reason: inputSource.isInstalled
                        ? "请先在系统设置中启用豆包输入法"
                        : "未安装豆包输入法",
                    voiceSessionFailed: true
                )
                return
            }
            let needsInputSourceSwitch = !inputSource.isSelected
            guard inputSource.selectDoubao() else {
                abortSession(reason: "无法切换到豆包输入法", voiceSessionFailed: true)
                return
            }
            rmDebug("🎙 input source after select=\(inputSource.currentSourceID ?? "unknown")")
            if needsInputSourceSwitch {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.inputSourceApplyDelay
                ) { [weak self] in
                    guard let self,
                          self.sessionGate.isCurrent(session),
                          self.phase == .priming else { return }
                    guard self.inputSource.isSelected else {
                        self.abortSession(
                            reason: "豆包输入法切换未生效",
                            voiceSessionFailed: true
                        )
                        return
                    }
                    self.startDoubaoVoice(session: session)
                }
            } else {
                startDoubaoVoice(session: session)
            }
        case .active:
            if !state.available || !state.producerActive || now - lastWriteAdvanceAt >= 0.3 {
                abortSession(reason: "遥控器音频采集已中断", voiceSessionFailed: true)
            }
        case .draining:
            if finalWriteIndex == nil {
                guard now - releasedAt >= 0.08 else { return }
                finalWriteIndex = state.writeIndex
                drainDeadline = now + 0.75
            }
            guard let finalWriteIndex else { return }
            let drained = state.available
                && state.consumerCount > 0
                && state.readIndex >= finalWriteIndex
            if drained || now >= drainDeadline { stopDoubaoAndFinish(session: session) }
        default:
            break
        }
    }

    private func startDoubaoVoice(session: UInt64) {
        guard sessionGate.isCurrent(session), phase == .priming else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        publish(.priming, "正在启动豆包语音…")
        guard functionKey.press() else {
            abortSession(
                reason: "Fn 按下发送失败，请检查辅助功能权限",
                voiceSessionFailed: true
            )
            return
        }
        rmDebug("🎙 Fn down generation=\(session); holding until audio drain completes")
        selectionInFlight = false
        fnHeldForSession = true
        if remoteReleasedDuringStart {
            beginDrain(session: session)
        } else {
            publish(.active, "正在使用遥控器麦克风")
        }
    }

    private func end() {
        let session = sessionGate.generation
        let release = sessionGate.release(
            generation: session, at: CACurrentMediaTime(), quickTapThreshold: 0.2
        )
        guard release != .stale else { return }
        switch phase {
        case .priming:
            if case .quickTap = release {
                abortSession(
                    reason: "快速点按发送 Return",
                    reportAsError: false,
                    voiceSessionFailed: false
                )
            } else if selectionInFlight || functionKey.isHeld {
                // Input-source selection can still be settling when the physical key is released.
                // Let promotion finish, then immediately drain while retaining the same Fn hold.
                remoteReleasedDuringStart = true
            } else {
                abortSession(
                    reason: "遥控器语音尚未准备好",
                    reportAsError: false,
                    voiceSessionFailed: true
                )
            }
        case .active:
            beginDrain(session: session)
        case .draining, .aborting, .idle:
            break
        }
    }

    private func beginDrain(session: UInt64) {
        guard sessionGate.isCurrent(session), phase == .active || phase == .priming else { return }
        releasedAt = CACurrentMediaTime()
        finalWriteIndex = nil
        publish(.draining, "正在接收尾音…")
        let hardFinish = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGate.isCurrent(session), self.phase == .draining else {
                return
            }
            self.stopDoubaoAndFinish(session: session)
        }
        finishWork = hardFinish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: hardFinish)
    }

    private func stopDoubaoAndFinish(session: UInt64) {
        guard sessionGate.isCurrent(session), phase == .draining else { return }
        finishWork?.cancel()
        finishWork = nil
        if fnHeldForSession || functionKey.isHeld {
            let released = functionKey.release()
            rmDebug(
                "🎙 Fn up generation=\(session) after drain success=\(released) source="
                    + (inputSource.currentSourceID ?? "unknown")
            )
            fnHeldForSession = false
            if !released {
                publish(.draining, "Fn 松开发送失败")
            }
        }
        complete(session: session)
    }

    private func complete(session: UInt64) {
        guard sessionGate.isCurrent(session), phase == .draining else { return }
        _ = demand.setActive(false)
        stopPolling()
        publish(.idle, "准备就绪")
    }

    func abort(reason: String) {
        resetSiriButtonGesture()
        abortSession(reason: reason, reportAsError: true, voiceSessionFailed: false)
    }

    private func abortSession(
        reason: String,
        reportAsError: Bool = true,
        voiceSessionFailed: Bool
    ) {
        rmDebug("🎙 abort phase=\(phase.rawValue) reason=\(reason)")
        if voiceSessionFailed { siriButtonGesture.voiceSessionFailed() }
        sessionGate.invalidate()
        selectionInFlight = false
        remoteReleasedDuringStart = false
        finalWriteIndex = nil
        drainDeadline = 0
        publish(.aborting, reason)
        timeoutWork?.cancel()
        finishWork?.cancel()
        timeoutWork = nil
        finishWork = nil
        stopPolling()
        if functionKey.isHeld {
            let released = functionKey.release()
            rmDebug("🎙 forced Fn up during abort success=\(released)")
        }
        fnHeldForSession = false
        _ = demand.setActive(false)
        publish(.idle, reportAsError ? reason : "准备就绪")
    }

    func shutdown() {
        resetSiriButtonGesture()
        abortSession(
            reason: "应用正在退出",
            reportAsError: false,
            voiceSessionFailed: false
        )
        srm_remote_audio_state_close()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func publish(_ newPhase: Phase, _ message: String) {
        phase = newPhase
        rmDebug("🎙 phase=\(newPhase.rawValue) status=\(message)")
    }

    private struct AudioState {
        let available: Bool
        let generation: UInt64
        let writeIndex: UInt64
        let readIndex: UInt64
        let producerActive: Bool
        let consumerCount: UInt32
    }

    private func audioState() -> AudioState {
        var audioGeneration: UInt64 = 0
        var writeIndex: UInt64 = 0
        var readIndex: UInt64 = 0
        var producerActive: UInt32 = 0
        var consumerCount: UInt32 = 0
        var startIOEpoch: UInt64 = 0
        let result = srm_remote_audio_state(
            &audioGeneration, &writeIndex, &readIndex, &producerActive,
            &consumerCount, &startIOEpoch
        )
        return AudioState(
            available: result == 0,
            generation: audioGeneration,
            writeIndex: writeIndex,
            readIndex: readIndex,
            producerActive: producerActive != 0,
            consumerCount: consumerCount
        )
    }
}
