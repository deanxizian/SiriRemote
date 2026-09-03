import XCTest
@testable import SiriRemoteCore

final class RemoteVoiceSessionTests: XCTestCase {
    func testQuickTapNeverReachesPromotionThreshold() {
        var gate = RemoteVoiceSessionGate()
        let session = gate.begin(at: 10)!
        XCTAssertFalse(gate.canPromote(generation: session, at: 10.199,
                                       minimumHold: 0.2, audioReady: true))
        assertRelease(gate.release(generation: session, at: 10.199,
                                   quickTapThreshold: 0.2),
                      isQuickTap: true, duration: 0.199)
        XCTAssertFalse(gate.isPressed)
    }

    func testPromotionNeedsBothHoldTimeAndAudio() {
        var gate = RemoteVoiceSessionGate()
        let session = gate.begin(at: 20)!
        XCTAssertFalse(gate.canPromote(generation: session, at: 20.3,
                                       minimumHold: 0.2, audioReady: false))
        XCTAssertTrue(gate.canPromote(generation: session, at: 20.2,
                                      minimumHold: 0.2, audioReady: true))
        assertRelease(gate.release(generation: session, at: 20.8,
                                   quickTapThreshold: 0.2),
                      isQuickTap: false, duration: 0.8)
    }

    func testInvalidationMakesEveryOldCallbackStale() {
        var gate = RemoteVoiceSessionGate()
        let old = gate.begin(at: 1)!
        let replacement = gate.invalidate()
        XCTAssertNotEqual(old, replacement)
        XCTAssertFalse(gate.isCurrent(old))
        XCTAssertFalse(gate.canPromote(generation: old, at: 5,
                                       minimumHold: 0.2, audioReady: true))
        XCTAssertEqual(gate.release(generation: old, at: 5,
                                    quickTapThreshold: 0.2), .stale)
        XCTAssertFalse(gate.isPressed)
    }

    func testDuplicateDownDoesNotCreateAnotherGeneration() {
        var gate = RemoteVoiceSessionGate()
        let first = gate.begin(at: 1)
        XCTAssertNil(gate.begin(at: 1.1))
        XCTAssertEqual(gate.generation, first)
    }

    private func assertRelease(
        _ release: RemoteVoiceSessionGate.Release,
        isQuickTap: Bool,
        duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual: TimeInterval
        switch release {
        case .quickTap(let value) where isQuickTap: actual = value
        case .held(let value) where !isQuickTap: actual = value
        default:
            return XCTFail("unexpected release result: \(release)", file: file, line: line)
        }
        XCTAssertEqual(actual, duration, accuracy: 0.000_001, file: file, line: line)
    }
}

final class SiriButtonGestureTests: XCTestCase {
    private let holdThreshold: TimeInterval = 0.2

    func testQuickTapEndsPrewarmAndSendsReturnImmediately() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 1.0), [.beginVoice])
        XCTAssertEqual(
            gesture.release(at: 1.1, holdThreshold: holdThreshold),
            [.endVoice, .sendReturn]
        )
        XCTAssertFalse(gesture.isPhysicallyPressed)
    }

    func testHoldRetainsNormalPushToTalkPair() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 5.0), [.beginVoice])
        XCTAssertFalse(gesture.canActivateVoice(at: 5.199, holdThreshold: holdThreshold))
        XCTAssertTrue(gesture.canActivateVoice(at: 5.2, holdThreshold: holdThreshold))
        XCTAssertEqual(
            gesture.release(at: 5.2, holdThreshold: holdThreshold),
            [.endVoice]
        )
        XCTAssertFalse(gesture.isPhysicallyPressed)
    }

    func testDuplicatePressIsIgnored() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 1.0), [.beginVoice])
        XCTAssertEqual(gesture.press(at: 1.1), [])
        XCTAssertEqual(
            gesture.release(at: 1.3, holdThreshold: holdThreshold),
            [.endVoice]
        )
    }

    func testVoiceFailureStillAllowsShortTapToSendReturn() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 1.0)
        gesture.voiceSessionFailed()
        XCTAssertEqual(
            gesture.release(at: 1.05, holdThreshold: holdThreshold),
            [.endVoice, .sendReturn]
        )
    }

    func testCancelAllClearsPhysicalStateAndDoesNotEmitAnAction() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 1.0)
        XCTAssertEqual(gesture.cancelAll(), [])
        XCTAssertFalse(gesture.isPhysicallyPressed)
        XCTAssertEqual(gesture.release(at: 1.1, holdThreshold: holdThreshold), [])
    }
}
