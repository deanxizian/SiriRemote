import XCTest
@testable import SiriRemoteCore

final class FixedButtonHoldTests: XCTestCase {
    private let timing = ButtonRepeatTiming(delay: 0.5, interval: 0.1)!

    func testAllTwelveButtonsHaveExplicitHoldAndReleaseBehavior() {
        XCTAssertEqual(FixedRemoteButton.allCases.count, 12)
        let repeating: Set<FixedRemoteButton> = [
            .menu, .ringUp, .ringDown, .ringLeft, .ringRight, .volumeUp, .volumeDown
        ]
        let onRelease: Set<FixedRemoteButton> = [.mute, .playPause, .power, .select]
        for button in FixedRemoteButton.allCases {
            XCTAssertEqual(button.repeatsWhileHeld, repeating.contains(button), button.rawValue)
            XCTAssertEqual(button.activatesOnRelease, onRelease.contains(button), button.rawValue)
            var state = FixedButtonHoldState()
            let begin: [FixedButtonHoldState.Command] = onRelease.contains(button)
                ? [] : [.beginHold(button)]
            XCTAssertEqual(state.press(button, at: 0, timing: timing), begin)
            for _ in 0..<20 {
                XCTAssertEqual(state.press(button, at: 0.1, timing: timing), [])
            }
            XCTAssertEqual(state.takeRepeats(at: 0.5),
                           repeating.contains(button) ? [.repeatHold(button)] : [])
            XCTAssertEqual(state.release(button, at: 0.6),
                           onRelease.contains(button) ? [.activate(button)] : [.endHold(button)])
            XCTAssertEqual(state.takeRepeats(at: 60), [])
            XCTAssertNil(state.nextRepeatAt)
            XCTAssertEqual(state.press(button, at: 61, timing: timing), begin)
        }
    }

    func testTogglesAndReturnWaitForOneGenuineRelease() {
        for button in [FixedRemoteButton.mute, .playPause, .power, .select] {
            var state = FixedButtonHoldState()
            XCTAssertEqual(state.press(button, at: 0, timing: timing), [])
            for time in [0.3, 0.5, 1, 3, 30, 600] {
                XCTAssertEqual(state.press(button, at: time, timing: timing), [])
                XCTAssertEqual(state.takeRepeats(at: time), [], button.rawValue)
                XCTAssertNil(state.nextRepeatAt)
            }
            XCTAssertEqual(state.release(button, at: 601), [.activate(button)])
            XCTAssertEqual(state.release(button, at: 602), [])
            XCTAssertEqual(state.press(button, at: 603, timing: timing), [])
            XCTAssertEqual(state.release(button, at: 603.1), [.activate(button)])
        }
    }

    func testTVBeginsImmediatelyAndOnlyEndsOnRelease() {
        var state = FixedButtonHoldState()
        XCTAssertEqual(state.press(.tv, at: 0, timing: timing), [.beginHold(.tv)])
        XCTAssertEqual(state.takeRepeats(at: 60), [])
        XCTAssertEqual(state.release(.tv, at: 61), [.endHold(.tv)])
    }

    func testCancelledReleaseNeverActivatesOneShotActions() {
        for button in [FixedRemoteButton.mute, .playPause, .power, .select] {
            var state = FixedButtonHoldState()
            _ = state.press(button, at: 0, timing: timing)
            XCTAssertEqual(state.release(button, at: 1, cancelled: true), [])
            XCTAssertEqual(state.release(button, at: 2), [])
            _ = state.press(button, at: 3, timing: timing)
            XCTAssertEqual(state.reset(), []) // sleep, reload, permissions or exit
            XCTAssertEqual(state.release(button, at: 4), [])
        }
    }

    func testInjectedRepeatDelayIntervalReleaseAndNoCatchUpBurst() {
        for button in FixedRemoteButton.allCases where button.repeatsWhileHeld {
            var state = FixedButtonHoldState()
            XCTAssertEqual(state.press(button, at: 0, timing: timing), [.beginHold(button)])
            XCTAssertEqual(state.takeRepeats(at: 0.499), [])
            XCTAssertEqual(state.takeRepeats(at: 0.5), [.repeatHold(button)])
            XCTAssertEqual(state.takeRepeats(at: 0.599), [])
            XCTAssertEqual(state.takeRepeats(at: 0.6), [.repeatHold(button)])
            XCTAssertEqual(state.takeRepeats(at: 50), [.repeatHold(button)])
            XCTAssertEqual(state.takeRepeats(at: 50), []) // no catch-up burst
            XCTAssertEqual(state.takeRepeats(at: 50.1), [.repeatHold(button)])
            XCTAssertEqual(state.release(button, at: 50.2), [.endHold(button)])
            XCTAssertEqual(state.release(button, at: 50.3), [])
            XCTAssertEqual(state.takeRepeats(at: 60), [])
        }
    }

    func testNewHoldUsesNewKeyboardTiming() {
        var state = FixedButtonHoldState()
        _ = state.press(.ringRight, at: 0, timing: timing)
        XCTAssertEqual(state.nextRepeatAt, 0.5)
        // Mirrored/down-repeat events cannot restart the delay or replace a hold's timing.
        let changed = ButtonRepeatTiming(delay: 0.8, interval: 0.2)!
        XCTAssertEqual(state.press(.ringRight, at: 0.2, timing: changed), [])
        XCTAssertEqual(state.takeRepeats(at: 0.5), [.repeatHold(.ringRight)])
        XCTAssertEqual(state.nextRepeatAt, 0.6)
        state.release(.ringRight, at: 1)
        _ = state.press(.ringRight, at: 2, timing: changed)
        XCTAssertEqual(state.nextRepeatAt, 2.8)
        XCTAssertEqual(state.takeRepeats(at: 2.8), [.repeatHold(.ringRight)])
        XCTAssertEqual(state.nextRepeatAt, 3)
    }

    func testDisabledOrInvalidRepeatTimingStillPairsDownAndUp() {
        for (delay, interval) in [(-1.0, 0.1), (0.5, 0), (0.5, -1),
                                  (.infinity, 0.1), (0.5, .nan)] {
            XCTAssertNil(ButtonRepeatTiming(delay: delay, interval: interval))
        }
        var state = FixedButtonHoldState()
        XCTAssertEqual(state.press(.ringRight, at: 0, timing: nil), [.beginHold(.ringRight)])
        XCTAssertNil(state.nextRepeatAt)
        XCTAssertEqual(state.takeRepeats(at: 600), [])
        XCTAssertEqual(state.release(.ringRight, at: 601), [.endHold(.ringRight)])
    }

    func testNativeMuteAndPlayRepeatsStaySuppressedBeyondOld300msWindow() {
        for button in [FixedRemoteButton.mute, .playPause, .volumeUp, .volumeDown] {
            var state = FixedButtonHoldState()
            var media = MediaKeySuppressionPolicy<FixedRemoteButton>()
            _ = state.press(button, at: 0, timing: timing)
            for time in [0.5, 1, 10, 600] {
                for repeatFlag in [false, true] {
                    XCTAssertTrue(media.shouldSuppress(
                        button, isDown: true, isRepeat: repeatFlag, volumeButton: nil,
                        handleVoiceChord: { _ in false },
                        isDuplicateRemotePress: { state.suppressesNativeMedia(button, at: time) }
                    ))
                }
            }
            state.release(button, at: 601)
            XCTAssertTrue(state.suppressesNativeMedia(button, at: 601.29))
            XCTAssertFalse(state.suppressesNativeMedia(button, at: 602))
            XCTAssertTrue(media.shouldSuppress(
                button, isDown: false, isRepeat: false, volumeButton: nil,
                handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
            ))
            XCTAssertFalse(media.shouldSuppress(
                button, isDown: true, isRepeat: false, volumeButton: nil,
                handleVoiceChord: { _ in false },
                isDuplicateRemotePress: { state.suppressesNativeMedia(button, at: 602) }
            ))
        }
    }

    func testOtherButtonActivityDoesNotLoseHeldMediaOwnership() {
        var state = FixedButtonHoldState()
        _ = state.press(.mute, at: 0, timing: timing)
        _ = state.press(.menu, at: 1, timing: timing)
        _ = state.press(.playPause, at: 2, timing: timing)
        XCTAssertTrue(state.suppressesNativeMedia(.mute, at: 10))
        XCTAssertTrue(state.suppressesNativeMedia(.playPause, at: 10))
        XCTAssertFalse(state.suppressesNativeMedia(.volumeUp, at: 10))
        XCTAssertFalse(state.suppressesNativeMedia(.menu, at: 10))
        state.release(.playPause, at: 11)
        XCTAssertTrue(state.suppressesNativeMedia(.mute, at: 20))
        XCTAssertFalse(state.suppressesNativeMedia(.playPause, at: 20))
    }

    func testConsumedVoiceVolumeNeverStartsRepeatingAfterSiriUp() {
        for button in [FixedRemoteButton.volumeUp, .volumeDown] {
            var state = FixedButtonHoldState()
            _ = state.press(button, at: 0, timing: timing)
            state.consumeUntilRelease(button)
            XCTAssertNil(state.nextRepeatAt)
            XCTAssertEqual(state.takeRepeats(at: 20), [])
            XCTAssertTrue(state.suppressesNativeMedia(button, at: 20))
            state.release(button, at: 21)
            _ = state.press(button, at: 22, timing: timing)
            XCTAssertEqual(state.takeRepeats(at: 22.5), [.repeatHold(button)])
        }
    }

    func testContextChangeCancelsOnlyTheConsumedDirectionRepeat() {
        var state = FixedButtonHoldState()
        _ = state.press(.ringLeft, at: 0, timing: timing)
        _ = state.press(.volumeUp, at: 0, timing: timing)
        state.consumeUntilRelease(.ringLeft)
        XCTAssertEqual(state.takeRepeats(at: 0.5), [.repeatHold(.volumeUp)])
        XCTAssertEqual(state.press(.ringLeft, at: 1, timing: timing), [])
        state.release(.ringLeft, at: 2)
        XCTAssertEqual(state.press(.ringLeft, at: 3, timing: timing), [.beginHold(.ringLeft)])
        XCTAssertTrue(state.takeRepeats(at: 3.5).contains(.repeatHold(.ringLeft)))
    }

    func testResetEndsHeldOutputsButDiscardsPendingReleaseActions() {
        var state = FixedButtonHoldState()
        for button in FixedRemoteButton.allCases { _ = state.press(button, at: 0, timing: timing) }
        state.release(.mute, at: 1) // reset also drops release-tail state
        XCTAssertEqual(state.reset(), FixedRemoteButton.allCases.filter {
            !$0.activatesOnRelease
        }.map { .endHold($0) })
        XCTAssertTrue(state.heldButtons.isEmpty)
        XCTAssertNil(state.nextRepeatAt)
        XCTAssertEqual(state.takeRepeats(at: 10), [])
        XCTAssertEqual(state.reset(), [])
        for button in FixedRemoteButton.allCases {
            XCTAssertFalse(state.suppressesNativeMedia(button, at: 1.1))
            XCTAssertEqual(state.release(button, at: 11), [])
        }
    }

    func testMirroredInterfacesKeepHoldUntilLastReleaseForEveryButton() {
        for button in FixedRemoteButton.allCases {
            var inputs = MultiRemoteButtonState<String, FixedRemoteButton>()
            var state = FixedButtonHoldState()
            XCTAssertEqual(inputs.update(source: "a", button: button, pressed: true), .globalDown)
            _ = state.press(button, at: 0, timing: timing)
            XCTAssertEqual(inputs.update(source: "b", button: button, pressed: true), .sourceOnly)
            XCTAssertEqual(inputs.update(source: "a", button: button, pressed: true), .duplicate)
            XCTAssertEqual(inputs.update(source: "a", button: button, pressed: false), .sourceOnly)
            XCTAssertEqual(state.takeRepeats(at: 1),
                           button.repeatsWhileHeld ? [.repeatHold(button)] : [])
            XCTAssertEqual(inputs.update(source: "b", button: button, pressed: false), .globalUp)
            XCTAssertEqual(state.release(button, at: 2),
                           button.activatesOnRelease ? [.activate(button)] : [.endHold(button)])
            XCTAssertTrue(state.heldButtons.isEmpty)
            XCTAssertEqual(state.takeRepeats(at: 3), [])
        }
    }

    func testLastInterfaceRemovalCancelsInsteadOfActivatingReleaseActions() {
        for button in FixedRemoteButton.allCases {
            var inputs = MultiRemoteButtonState<String, FixedRemoteButton>()
            var state = FixedButtonHoldState()
            _ = inputs.update(source: "a", button: button, pressed: true)
            _ = state.press(button, at: 0, timing: timing)
            _ = inputs.update(source: "b", button: button, pressed: true)
            XCTAssertTrue(inputs.removeSource("a").isEmpty)
            let released = inputs.removeSource("b")
            XCTAssertEqual(released, [button])
            for removed in released {
                XCTAssertEqual(state.release(removed, at: 2, cancelled: true),
                               button.activatesOnRelease ? [] : [.endHold(button)])
            }
            XCTAssertEqual(state.release(button, at: 3), [])
        }
    }
}
