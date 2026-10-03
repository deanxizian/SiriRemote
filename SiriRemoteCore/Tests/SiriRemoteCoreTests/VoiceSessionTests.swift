import XCTest
@testable import SiriRemoteCore

final class VoiceSessionTests: XCTestCase {
    private func audio(_ write: UInt64 = 9600, read: UInt64 = 0,
                       generation: UInt64 = 10) -> VoiceSession.Audio {
        .init(available: true, generation: generation, write: write,
              read: read, active: true, consumers: 1)
    }

    private func active() -> VoiceSession {
        var voice = VoiceSession()
        XCTAssertEqual(voice.press(at: 0), [.beginCapture(1)])
        XCTAssertEqual(voice.poll(audio(), at: 0.3), [.prepareDestination(1)])
        XCTAssertEqual(voice.destinationPrepared(session: 1, at: 0.3,
                                                success: true, settleDelay: 0), [])
        XCTAssertEqual(voice.poll(audio(), at: 0.32), [.startRecognition(1)])
        XCTAssertEqual(voice.recognitionStarted(session: 1, at: 0.32, success: true), [])
        XCTAssertEqual(voice.phase, .active)
        return voice
    }

    func testShortPressCancelsWithoutFnOrInputSourceSwitch() {
        for duration in [0.1, 0.2, 0.25, 0.299] {
            var voice = VoiceSession()
            _ = voice.press(at: 0)
            XCTAssertEqual(voice.poll(audio(), at: duration), [])
            XCTAssertEqual(voice.release(at: duration), [.endCapture(1)])
            XCTAssertEqual(voice.phase, .idle)
        }
    }

    func testExact300MillisecondBoundaryStartsVoiceNotTap() {
        var voice = VoiceSession()
        _ = voice.press(at: 5)
        XCTAssertEqual(voice.poll(audio(), at: 5.299), [])
        XCTAssertEqual(voice.poll(audio(), at: 5.3), [.prepareDestination(1)])
        _ = voice.destinationPrepared(session: 1, at: 5.3, success: true, settleDelay: 0)
        XCTAssertEqual(voice.release(at: 5.3), [])
        XCTAssertEqual(voice.poll(audio(), at: 5.32), [.startRecognition(1)])
        _ = voice.recognitionStarted(session: 1, at: 5.32, success: true)
        XCTAssertEqual(voice.phase, .draining)
    }

    func testPreparationTimeoutAndLateInputSourceCallback() {
        var voice = VoiceSession()
        _ = voice.press(at: 0)
        XCTAssertEqual(voice.poll(.init(), at: 1.5),
                       [.endCapture(1), .failure("1.5 秒内没有收到遥控器音频")])
        XCTAssertEqual(voice.destinationPrepared(session: 1, at: 2,
                                                success: true, settleDelay: 0), [])
        XCTAssertEqual(voice.phase, .idle)
    }

    func testSwitchOnlyOnceAndReleaseWhileSwitchSettles() {
        var voice = VoiceSession()
        _ = voice.press(at: 0)
        _ = voice.poll(audio(), at: 0.3)
        _ = voice.destinationPrepared(session: 1, at: 0.3, success: true, settleDelay: 0.25)
        XCTAssertEqual(voice.poll(audio(10000), at: 0.4), [])
        _ = voice.release(at: 0.41)
        XCTAssertEqual(voice.poll(audio(10500), at: 0.54), [])
        XCTAssertEqual(voice.poll(audio(10500), at: 0.56), [.startRecognition(1)])
        _ = voice.recognitionStarted(session: 1, at: 0.56, success: true)
        XCTAssertEqual(voice.phase, .draining)
        XCTAssertEqual(voice.poll(audio(10500, read: 10500), at: 0.65),
                       [.seal(1, 10500), .stopRecognition(1), .endCapture(1)])
    }

    func testLateFrameRestartsQuietWindowBeforeDrain() {
        var voice = active()
        _ = voice.release(at: 1)
        XCTAssertEqual(voice.poll(audio(11000), at: 1.07), [])
        XCTAssertEqual(voice.poll(audio(12000), at: 1.12), [])
        XCTAssertEqual(voice.poll(audio(12000, read: 12000), at: 1.19), [])
        XCTAssertEqual(voice.poll(audio(12000, read: 12000), at: 1.21),
                       [.seal(1, 12000), .stopRecognition(1), .endCapture(1)])
    }

    func testTailHasHardUpperBoundAndDrainTimeout() {
        var voice = active()
        _ = voice.release(at: 1)
        _ = voice.poll(audio(11000), at: 1.1)
        _ = voice.poll(audio(12000), at: 1.2)
        XCTAssertEqual(voice.poll(audio(13000), at: 1.31), [.seal(1, 13000)])
        XCTAssertEqual(voice.poll(audio(14000), at: 1.8), [])
        XCTAssertEqual(voice.poll(audio(14000), at: 2.07), [.stopRecognition(1), .endCapture(1)])
    }

    func testPendingPressStartsAfterOldFnAndLeaseEnd() {
        var voice = active()
        _ = voice.release(at: 1)
        _ = voice.poll(audio(11000), at: 1.03)
        XCTAssertEqual(voice.press(at: 1.04), [.seal(1, 11000)])
        XCTAssertEqual(voice.press(at: 1.05), [])
        XCTAssertEqual(voice.poll(audio(12000, read: 11000), at: 1.06),
                       [.stopRecognition(1), .endCapture(1), .beginCapture(2)])
        XCTAssertEqual(voice.phase, .priming)
        XCTAssertEqual(voice.poll(audio(9600, generation: 12), at: 1.339), [])
        XCTAssertEqual(voice.poll(audio(9600, generation: 12), at: 1.34), [.prepareDestination(2)])
    }

    func testPendingShortPressStillCancelsAfterOldDrainFinishes() {
        var voice = active()
        _ = voice.release(at: 1)
        _ = voice.press(at: 1.04)
        _ = voice.poll(audio(read: 9600), at: 1.06)
        XCTAssertEqual(voice.poll(audio(generation: 12), at: 1.3), [])
        XCTAssertEqual(voice.release(at: 1.31), [.endCapture(2)])
        XCTAssertEqual(voice.phase, .idle)
    }

    func testReleasedPendingPressIsNotStartedLater() {
        var voice = active()
        _ = voice.release(at: 1)
        _ = voice.press(at: 1.02)
        _ = voice.release(at: 1.1)
        XCTAssertEqual(voice.poll(audio(read: 9600), at: 1.2), [.stopRecognition(1), .endCapture(1)])
        XCTAssertEqual(voice.phase, .idle)
    }

    func testProducerRestartCannotSatisfyPreviousDrain() {
        var voice = active()
        _ = voice.release(at: 1)
        XCTAssertEqual(voice.poll(audio(read: 100000, generation: 11), at: 1.1),
                       [.stopRecognition(1), .endCapture(1), .failure("遥控器音频会话已中断")])
    }

    func testAbortAlwaysReleasesAndDropsPendingPress() {
        for reason in ["断连", "睡眠", "权限撤销", "配置变化", "应用退出"] {
            var voice = active()
            _ = voice.release(at: 1)
            _ = voice.press(at: 1.01)
            XCTAssertEqual(voice.abort(reason: reason), [.stopRecognition(1), .endCapture(1), .failure(reason)])
            XCTAssertNil(voice.pendingPressAt)
            XCTAssertEqual(voice.poll(audio(), at: 2), [])
            XCTAssertEqual(voice.abort(reason: nil), [])
        }
    }

    func testPermissionOrHelperFailureDoesNotLeaveFnHeld() {
        var voice = active()
        XCTAssertEqual(voice.poll(.init(), at: 0.4),
                       [.stopRecognition(1), .endCapture(1), .failure("遥控器音频会话已中断")])
    }

    func testDuplicateEdgesDoNotCreateExtraLeaseOrFn() {
        var voice = active()
        XCTAssertEqual(voice.press(at: 0.35), [])
        XCTAssertEqual(voice.release(at: 0.4), [])
        XCTAssertEqual(voice.release(at: 0.41), [])
        XCTAssertEqual(voice.phase, .draining)
    }

    func testStaleFnCompletionDoesNotReleaseNewerHeldKey() {
        var voice = active()
        XCTAssertEqual(voice.recognitionStarted(session: 99, at: 0.4, success: true), [])
        XCTAssertEqual(voice.phase, .active)
    }

    func testInputSourceFailureEndsCaptureWithoutFn() {
        var voice = VoiceSession()
        _ = voice.press(at: 0)
        _ = voice.poll(audio(), at: 0.3)
        XCTAssertEqual(voice.destinationPrepared(session: 1, at: 0.3, success: false, settleDelay: 0),
                       [.endCapture(1), .failure("语音工具未就绪")])
    }

    func testFnFailureEndsCaptureAndIsNotRetried() {
        var voice = VoiceSession()
        _ = voice.press(at: 0)
        _ = voice.poll(audio(), at: 0.3)
        _ = voice.destinationPrepared(session: 1, at: 0.3, success: true, settleDelay: 0)
        _ = voice.poll(audio(), at: 0.32)
        XCTAssertEqual(voice.recognitionStarted(session: 1, at: 0.32, success: false),
                       [.endCapture(1), .failure("语音快捷键发送失败，请检查辅助功能权限")])
        XCTAssertEqual(voice.poll(audio(), at: 0.4), [])
    }

    func testFrozenProducerReleasesFnAtDeadline() {
        var voice = active()
        XCTAssertEqual(voice.poll(audio(), at: 0.63),
                       [.stopRecognition(1), .endCapture(1), .failure("遥控器音频采集已中断")])
    }
}
