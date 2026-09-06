import XCTest
@testable import SiriRemoteCore


final class SiriButtonGestureTests: XCTestCase {
    private let holdThreshold = SiriButtonGestureMachine.holdThreshold

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
        XCTAssertEqual(holdThreshold, 0.3)
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 5.0), [.beginVoice])
        XCTAssertFalse(gesture.canActivateVoice(at: 5.299, holdThreshold: holdThreshold))
        XCTAssertTrue(gesture.canActivateVoice(at: 5.3, holdThreshold: holdThreshold))
        XCTAssertEqual(
            gesture.release(at: 5.3, holdThreshold: holdThreshold),
            [.endVoice]
        )
        XCTAssertFalse(gesture.isPhysicallyPressed)
    }

    func testPressesBetweenOldAndNewThresholdSendReturnOnRelease() {
        for duration in [0.2, 0.25, 0.299] {
            var gesture = SiriButtonGestureMachine()
            XCTAssertEqual(gesture.press(at: 5), [.beginVoice])
            XCTAssertFalse(gesture.canActivateVoice(at: 5 + duration, holdThreshold: holdThreshold))
            XCTAssertEqual(gesture.release(at: 5 + duration, holdThreshold: holdThreshold),
                           [.endVoice, .sendReturn])
        }
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
