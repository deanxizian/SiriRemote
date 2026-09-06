import AppKit
import ApplicationServices
import Foundation

@MainActor
final class DoubaoVoiceCoordinator {
    private let inputSource = DoubaoInputSourceCoordinator()
    private let functionKey = FunctionKeyLatch()
    private let demand = RemoteAudioDemand()
    private var gesture = SiriButtonGestureMachine()
    private var voice = DoubaoVoiceSession()
    private var pollTimer: Timer?
    private var deferredReturn = false

    func handleSiri(pressed: Bool) {
        let now = CACurrentMediaTime()
        let commands = pressed ? gesture.press(at: now)
            : gesture.release(at: now, holdThreshold: SiriButtonGestureMachine.holdThreshold)
        for command in commands {
            switch command {
            case .beginVoice: apply(voice.press(at: now))
            case .endVoice: apply(voice.release(at: now))
            case .sendReturn:
                if voice.phase == .draining { deferredReturn = true }
                else { FixedKeyEmitter.tap(.enter) }
            }
        }
        rmDebug("🎙 Siri \(pressed ? "down" : "up") phase=\(voice.phase)")
    }

    private func apply(_ commands: [DoubaoVoiceSession.Command]) {
        for command in commands {
            switch command {
            case .beginCapture(let session):
                if functionKey.isHeld { _ = functionKey.release() }
                if !demand.begin(session: session) {
                    apply(voice.abort(reason: "无法启动遥控器语音采集服务"))
                }
            case .endCapture(let session):
                demand.end(session: session)
            case .seal(let session, let frame):
                demand.seal(session: session, endFrame: frame)
            case .selectInputSource(let session):
                let switching = !inputSource.isSelected
                let selected = inputSource.isAvailable && inputSource.selectDoubao()
                apply(voice.inputSourceSelected(
                    session: session, at: CACurrentMediaTime(), success: selected,
                    settleDelay: switching ? 0.25 : 0
                ))
            case .pressFn(let session):
                let success = inputSource.isSelected && AXIsProcessTrusted() && functionKey.press()
                apply(voice.fnResult(session: session, at: CACurrentMediaTime(), success: success))
                rmDebug("🎙 Fn down session=\(session) success=\(success)")
            case .releaseFn:
                let released = functionKey.release()
                rmDebug("🎙 Fn up success=\(released)")
            case .failure(let reason):
                rmDebug("🎙 \(reason)")
            }
        }
        updatePolling()
    }

    private func updatePolling() {
        if voice.phase == .idle {
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
        guard AXIsProcessTrusted() else { abort(reason: "辅助功能权限已关闭"); return }
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
        if functionKey.isHeld { _ = functionKey.release() }
    }

    func shutdown() {
        abort(reason: "应用正在退出")
        srm_remote_audio_state_close()
    }
}
