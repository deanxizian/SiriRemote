import XCTest
@testable import SiriRemoteCore

final class SiriButtonGestureTests: XCTestCase {
    private let holdThreshold = SiriButtonGestureMachine.holdThreshold

    func testQuickTapStopsCaptureImmediatelyButWaitsForDoubleTapWindow() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 1), [.beginVoice])
        XCTAssertEqual(gesture.release(at: 1.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertFalse(gesture.isPhysicallyPressed)
        XCTAssertEqual(gesture.pendingTapDeadline ?? -1, 1.4, accuracy: 1e-9)
        XCTAssertEqual(gesture.poll(at: 1.399), [])
        XCTAssertEqual(gesture.poll(at: 1.4), [.sendReturn])
        XCTAssertEqual(gesture.poll(at: 2), [])
        XCTAssertNil(gesture.pendingTapDeadline)
    }

    func testTwoShortTapsSwitchExactlyOnceWithoutReturn() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.release(at: 0.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.press(at: 0.2), [.beginVoice])
        XCTAssertNil(gesture.pendingTapDeadline)
        XCTAssertEqual(gesture.poll(at: 0.4), []) // original single-tap timer cannot fire
        XCTAssertEqual(gesture.release(at: 0.45, holdThreshold: holdThreshold),
                       [.endVoice, .switchVoiceTarget])
        XCTAssertEqual(gesture.release(at: 0.46, holdThreshold: holdThreshold), [])
        XCTAssertEqual(gesture.poll(at: 2), [])
    }

    func testDoubleTapIntervalBoundaryStartsANewSingleTap() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1, holdThreshold: holdThreshold)
        // Even a delayed timer cannot turn a late press into a double tap.
        XCTAssertEqual(gesture.press(at: 0.4), [.sendReturn, .beginVoice])
        XCTAssertEqual(gesture.release(at: 0.5, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 0.8), [.sendReturn])
    }

    func testSecondPressHeldForRecordingConsumesFirstTapWithoutSwitching() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1, holdThreshold: holdThreshold)
        _ = gesture.press(at: 0.2)
        XCTAssertTrue(gesture.canActivateVoice(at: 0.5, holdThreshold: holdThreshold))
        XCTAssertEqual(gesture.poll(at: 0.6), [])
        XCTAssertEqual(gesture.release(at: 1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 2), [])
    }

    func testTripleTapIsOneSwitchThenOneDelayedReturn() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.05, holdThreshold: holdThreshold)
        _ = gesture.press(at: 0.1)
        XCTAssertEqual(gesture.release(at: 0.15, holdThreshold: holdThreshold),
                       [.endVoice, .switchVoiceTarget])
        _ = gesture.press(at: 0.2)
        XCTAssertEqual(gesture.release(at: 0.25, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 0.55), [.sendReturn])
    }

    func testHoldRetainsNormalPushToTalkPair() {
        XCTAssertEqual(holdThreshold, 0.3)
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 5), [.beginVoice])
        XCTAssertFalse(gesture.canActivateVoice(at: 5.299, holdThreshold: holdThreshold))
        XCTAssertTrue(gesture.canActivateVoice(at: 5.3, holdThreshold: holdThreshold))
        XCTAssertEqual(gesture.release(at: 5.3, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertFalse(gesture.isPhysicallyPressed)
        XCTAssertEqual(gesture.poll(at: 6), [])
    }

    func testPressesBelow300msRemainSingleTaps() {
        for duration in [0.2, 0.25, 0.299] {
            var gesture = SiriButtonGestureMachine()
            XCTAssertEqual(gesture.press(at: 5), [.beginVoice])
            XCTAssertFalse(gesture.canActivateVoice(at: 5 + duration, holdThreshold: holdThreshold))
            XCTAssertEqual(gesture.release(at: 5 + duration, holdThreshold: holdThreshold),
                           [.endVoice])
            XCTAssertEqual(gesture.poll(at: 5 + duration + 0.3), [.sendReturn])
        }
    }

    func testDuplicatePhysicalEdgesDoNotCountAsSecondTap() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertEqual(gesture.press(at: 1), [.beginVoice])
        XCTAssertEqual(gesture.press(at: 1.05), [])
        XCTAssertEqual(gesture.release(at: 1.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.release(at: 1.2, holdThreshold: holdThreshold), [])
        XCTAssertEqual(gesture.poll(at: 1.4), [.sendReturn])
    }

    func testVoiceFailureStillAllowsTapOrDoubleTapWithoutRecognition() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 1)
        gesture.voiceSessionFailed()
        XCTAssertEqual(gesture.release(at: 1.05, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 1.35), [.sendReturn])
        _ = gesture.press(at: 2)
        _ = gesture.release(at: 2.05, holdThreshold: holdThreshold)
        _ = gesture.press(at: 2.1)
        gesture.voiceSessionFailed()
        XCTAssertEqual(gesture.release(at: 2.15, holdThreshold: holdThreshold),
                       [.endVoice, .switchVoiceTarget])
    }

    func testCancelAllClearsHeldPendingAndSecondTapStates() {
        for cancelledAt in [0, 1, 2] {
            var gesture = SiriButtonGestureMachine()
            _ = gesture.press(at: 0)
            if cancelledAt >= 1 { _ = gesture.release(at: 0.05, holdThreshold: holdThreshold) }
            if cancelledAt >= 2 { _ = gesture.press(at: 0.1) }
            XCTAssertEqual(gesture.cancelAll(), [])
            XCTAssertFalse(gesture.isPhysicallyPressed)
            XCTAssertNil(gesture.pendingTapDeadline)
            XCTAssertEqual(gesture.release(at: 0.2, holdThreshold: holdThreshold), [])
            XCTAssertEqual(gesture.poll(at: 1), [])
            _ = gesture.press(at: 2)
            XCTAssertEqual(gesture.release(at: 2.1, holdThreshold: holdThreshold), [.endVoice])
            XCTAssertEqual(gesture.poll(at: 2.4), [.sendReturn])
        }
    }

    func testVolumeChordsRequireTypelessAndAnActualSiriHold() {
        var gesture = SiriButtonGestureMachine()
        XCTAssertNil(gesture.consumeVoiceChord(.up, target: .typeless))
        _ = gesture.press(at: 0)
        XCTAssertNil(gesture.consumeVoiceChord(.up, target: .doubao))
        XCTAssertNil(gesture.consumeVoiceChord(.down, target: .doubao))
        XCTAssertEqual(gesture.release(at: 0.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 0.4), [.sendReturn])
        _ = gesture.press(at: 1)
        XCTAssertEqual(gesture.consumeVoiceChord(.up, target: .typeless), .translate)
        XCTAssertEqual(gesture.consumeVoiceChord(.down, target: .typeless), .askAnything)
        XCTAssertEqual(gesture.release(at: 1.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 1.4), [])
        XCTAssertNil(gesture.consumeVoiceChord(.down, target: .typeless))
    }

    func testSecondTapWithVolumeChordDoesNotSwitchOrSendReturn() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.05, holdThreshold: holdThreshold)
        _ = gesture.press(at: 0.1)
        XCTAssertEqual(gesture.consumeVoiceChord(.up, target: .typeless), .translate)
        XCTAssertEqual(gesture.release(at: 0.2, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 1), [])
    }

    func testCancelledChordCannotSuppressTheNextOrdinaryShortTap() {
        var gesture = SiriButtonGestureMachine()
        _ = gesture.press(at: 0)
        _ = gesture.consumeVoiceChord(.up, target: .typeless)
        _ = gesture.cancelAll()
        _ = gesture.press(at: 1)
        XCTAssertEqual(gesture.release(at: 1.1, holdThreshold: holdThreshold), [.endVoice])
        XCTAssertEqual(gesture.poll(at: 1.4), [.sendReturn])
    }

    func testSwitchReadinessChecksOnlyTheDestinationAndHasNoInputSourceSideEffects() {
        XCTAssertEqual(VoiceTarget.doubao.alternate, .typeless)
        XCTAssertEqual(VoiceTarget.typeless.alternate, .doubao)
        for enabled in [false, true] {
            for running in [false, true] {
                XCTAssertEqual(VoiceTarget.doubao.canSwitchToAlternate(
                    doubaoEnabled: enabled, typelessRunning: running
                ), running)
                XCTAssertEqual(VoiceTarget.typeless.canSwitchToAlternate(
                    doubaoEnabled: enabled, typelessRunning: running
                ), enabled)
            }
        }
    }
}
