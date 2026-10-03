import AppKit
import ApplicationServices
import Foundation

@MainActor
final class VoiceCoordinator {
    private let inputSource = DoubaoInputSourceCoordinator()
    private let triggerKey = VoiceKeyLatch(post: VoiceKeyEmitter.post)
    private let demand = RemoteAudioDemand()
    private var target: VoiceTarget = .doubao
    private lazy var shortcut = VoiceShortcutController(
        setKey: { [weak self] target, down in
            guard let self else { return false }
            if down {
                guard AXIsProcessTrusted(), target != .typeless || TypelessIntegration.isRunning
                else { return false }
                return self.triggerKey.press(target.triggerKey)
            }
            return self.triggerKey.release()
        },
        onStarted: { [weak self] session, success in
            guard let self else { return }
            self.apply(self.voice.recognitionStarted(
                session: session, at: CACurrentMediaTime(), success: success
            ))
        },
        onStopFailure: { rmDebug("🎙 voice shortcut stop failed; check Accessibility and the voice app") }
    )
    private var gesture = SiriButtonGestureMachine()
    private var voice = VoiceSession()
    private var pollTimer: Timer?
    private var deferredReturn = false

    func setTarget(_ target: VoiceTarget) {
        guard target != self.target else { return }
        abort(reason: "语音工具已更改")
        self.target = target
    }

    func handleSiri(pressed: Bool) {
        let now = CACurrentMediaTime()
        let commands = pressed ? gesture.press(at: now)
            : gesture.release(at: now, holdThreshold: SiriButtonGestureMachine.holdThreshold)
        for command in commands {
            switch command {
            case .beginVoice: apply(voice.press(at: now))
            case .endVoice: apply(voice.release(at: now))
            case .sendReturn:
                if voice.phase == .draining || shortcut.isBusy { deferredReturn = true }
                else { FixedKeyEmitter.tap(.enter) }
            }
        }
        rmDebug("🎙 Siri \(pressed ? "down" : "up") phase=\(voice.phase)")
    }

    private func apply(_ commands: [VoiceSession.Command]) {
        for command in commands {
            switch command {
            case .beginCapture(let session):
                if !demand.begin(session: session) {
                    apply(voice.abort(reason: "无法启动遥控器语音采集服务"))
                }
            case .endCapture(let session):
                // Also cancels a pending start tap when prepare/permission/capture fails before
                // the voice state machine has received its start acknowledgement.
                shortcut.end(session: session, at: CACurrentMediaTime())
                demand.end(session: session)
            case .seal(let session, let frame):
                demand.seal(session: session, endFrame: frame)
            case .prepareDestination(let session):
                let switching = target.requiresInputSourceSelection && !inputSource.isSelected
                let ready: Bool
                if target.requiresInputSourceSelection {
                    ready = inputSource.isAvailable && inputSource.selectDoubao()
                } else {
                    // Typeless is a standalone global-shortcut app, not a TIS input source.
                    // Do not activate its window or disturb the user's current text field.
                    ready = TypelessIntegration.isRunning
                }
                apply(voice.destinationPrepared(
                    session: session, at: CACurrentMediaTime(), success: ready,
                    settleDelay: switching ? 0.25 : 0
                ))
            case .startRecognition(let session):
                guard !target.requiresInputSourceSelection || inputSource.isSelected else {
                    apply(voice.recognitionStarted(
                        session: session, at: CACurrentMediaTime(), success: false
                    ))
                    continue
                }
                shortcut.start(session: session, target: target, at: CACurrentMediaTime())
                rmDebug("🎙 \(target.rawValue) start session=\(session)")
            case .stopRecognition(let session):
                shortcut.end(session: session, at: CACurrentMediaTime())
            case .failure(let reason):
                rmDebug("🎙 \(reason)")
            }
        }
        updatePolling()
    }

    private func updatePolling() {
        if voice.phase == .idle && !shortcut.isBusy {
            pollTimer?.invalidate()
            pollTimer = nil
            if deferredReturn {
                deferredReturn = false
                FixedKeyEmitter.tap(.enter)
            }
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func poll() {
        // Finish any pending key-up even if capture has already stopped. Never let a timer from
        // the previous session release the following session's modifier.
        shortcut.poll(at: CACurrentMediaTime())
        guard AXIsProcessTrusted() else { abort(reason: "辅助功能权限已关闭"); return }
        guard target != .typeless || TypelessIntegration.isRunning else {
            abort(reason: "Typeless 已退出")
            return
        }
        var generation: UInt64 = 0, write: UInt64 = 0, read: UInt64 = 0, epoch: UInt64 = 0
        var active: UInt32 = 0, consumers: UInt32 = 0
        let available = srm_remote_audio_state(
            &generation, &write, &read, &active, &consumers, &epoch
        ) == 0
        apply(voice.poll(.init(available: available, generation: generation,
                               write: write, read: read, active: active != 0,
                               consumers: consumers), at: CACurrentMediaTime()))
    }

    func abort(reason: String) {
        _ = gesture.cancelAll()
        deferredReturn = false
        apply(voice.abort(reason: reason))
        shortcut.cancelAll(at: CACurrentMediaTime())
        updatePolling()
    }

    func shutdown() {
        abort(reason: "应用正在退出")
        shortcut.shutdown()
        triggerKey.release()
        pollTimer?.invalidate()
        pollTimer = nil
        srm_remote_audio_state_close()
    }
}
