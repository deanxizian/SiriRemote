import XCTest
@testable import SiriRemoteCore

/// Exercises the production lifecycle, shortcut controller and key latch, with OS effects replaced.
final class VoicePipelineTests: XCTestCase {
    @MainActor
    private final class Pipeline {
        var target: VoiceTarget
        var doubaoEnabled = true
        var typelessRunning = true
        var switchCount = 0
        var rejectedSwitchCount = 0
        var now: TimeInterval = 0
        var voice = VoiceSession()
        var gesture = SiriButtonGestureMachine()
        var mediaSuppression = MediaKeySuppressionPolicy<VoiceVolumeButton>()
        var keys: [Bool] = []
        var triggerKeys: [VoiceTriggerKey] = []
        var returnCount = 0
        var volumeCount = 0
        var sourceSelections = 0
        var capture = false
        lazy var keyLatch = VoiceKeyLatch { [unowned self] edge in
            keys.append(edge.isDown)
            triggerKeys.append(edge.key)
            return true
        }
        lazy var shortcut = VoiceShortcutController(
            setShortcut: { [unowned self] shortcut, down in
                down ? keyLatch.press(shortcut) : keyLatch.release()
            },
            onStarted: { [unowned self] id, success in
                apply(voice.recognitionStarted(session: id, at: now, success: success))
            },
            onStopFailure: { XCTFail("Unexpected stop failure") }
        )

        init(_ target: VoiceTarget) { self.target = target }

        func press(_ time: TimeInterval) { now = time; handle(gesture.press(at: time)) }
        func release(_ time: TimeInterval) {
            now = time
            handle(gesture.release(at: time, holdThreshold: SiriButtonGestureMachine.holdThreshold))
        }
        func volume(_ button: VoiceVolumeButton) {
            if !consumeVolumeChord(button) { volumeCount += 1 }
        }
        func consumeVolumeChord(_ button: VoiceVolumeButton) -> Bool {
            if let mode = gesture.consumeVoiceChord(button, target: target) {
                _ = voice.selectTypelessMode(mode)
                return true
            }
            return false
        }
        @discardableResult
        func systemVolume(_ button: VoiceVolumeButton, down: Bool = true,
                          repeatKey: Bool = false, duplicateHID: Bool = false) -> Bool {
            let suppressed = mediaSuppression.shouldSuppress(
                button, isDown: down, isRepeat: repeatKey, volumeButton: button,
                handleVoiceChord: { [unowned self] in consumeVolumeChord($0) },
                isDuplicateRemotePress: { duplicateHID }
            )
            if down, !suppressed { volumeCount += 1 }
            return suppressed
        }
        func handle(_ commands: [SiriButtonGestureMachine.Command]) {
            for command in commands {
                switch command {
                case .beginVoice: apply(voice.press(at: now))
                case .endVoice: apply(voice.release(at: now))
                case .sendReturn: returnCount += 1
                case .switchVoiceTarget:
                    if voice.phase == .idle, !shortcut.isBusy,
                       target.canSwitchToAlternate(doubaoEnabled: doubaoEnabled,
                                                   typelessRunning: typelessRunning) {
                        target = target.alternate
                        switchCount += 1
                    } else {
                        rejectedSwitchCount += 1
                    }
                }
            }
        }
        func poll(_ time: TimeInterval, write: UInt64 = 9600, read: UInt64 = 0) {
            now = time
            handle(gesture.poll(at: time))
            shortcut.poll(at: time)
            apply(voice.poll(.init(available: true, generation: 10, write: write,
                                   read: read, active: true, consumers: 1), at: time))
        }

        func apply(_ commands: [VoiceSession.Command]) {
            for command in commands {
                switch command {
                case .beginCapture: capture = true
                case .endCapture(let id):
                    shortcut.end(session: id, at: now)
                    capture = false
                case .prepareDestination(let id):
                    if target.requiresInputSourceSelection { sourceSelections += 1 }
                    apply(voice.destinationPrepared(session: id, at: now,
                                                    success: true, settleDelay: 0))
                case .startRecognition(let id):
                    shortcut.start(session: id, target: target, mode: voice.typelessMode, at: now)
                case .stopRecognition(let id):
                    shortcut.end(session: id, at: now)
                case .seal, .failure: break
                }
            }
        }
    }

    @MainActor func testShortPressNeverTriggersEitherRecognizer() async {
        for target in VoiceTarget.allCases {
            for duration in [0.1, 0.2, 0.299] {
                let p = Pipeline(target)
                p.press(0)
                p.poll(duration)
                p.release(duration)
                p.poll(2)
                XCTAssertEqual(p.keys, [])
                XCTAssertEqual(p.sourceSelections, 0)
                XCTAssertFalse(p.capture)
                XCTAssertFalse(p.shortcut.isBusy)
            }
        }
    }

    @MainActor func testDoubleTapSwitchesBothWaysWithoutReturnOrRecognizerShortcuts() async {
        for target in VoiceTarget.allCases {
            let p = Pipeline(target)
            p.press(0)
            p.release(0.05)
            XCTAssertFalse(p.capture)
            p.press(0.1)
            p.release(0.2)
            p.poll(1)
            XCTAssertEqual(p.target, target.alternate)
            XCTAssertEqual(p.switchCount, 1)
            p.press(2)
            p.release(2.05)
            p.press(2.1)
            p.release(2.2)
            p.poll(3)
            XCTAssertEqual(p.target, target)
            XCTAssertEqual(p.switchCount, 2)
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertEqual(p.sourceSelections, 0)
            XCTAssertTrue(p.keys.isEmpty)
            XCTAssertFalse(p.capture)
            XCTAssertFalse(p.shortcut.isBusy)
        }
    }

    @MainActor func testNextHoldUsesNewTargetAndKeepsNormalVoiceLifecycle() async {
        for original in VoiceTarget.allCases {
            let p = Pipeline(original)
            p.press(0)
            p.release(0.05)
            p.press(0.1)
            p.release(0.2)
            // No waiting for the old single-tap deadline: hold can start immediately after switch.
            p.press(0.21)
            p.poll(0.51)
            p.poll(0.53)
            p.poll(0.65)
            XCTAssertEqual(p.voice.phase, .active)
            XCTAssertEqual(p.target, original.alternate)
            let typeless = p.target == .typeless
            XCTAssertEqual(p.triggerKeys, typeless ? [.function, .function] : [.rightCommand])
            XCTAssertEqual(p.sourceSelections, typeless ? 0 : 1)
            p.release(1)
            p.poll(1.1, read: 9600)
            p.poll(1.22, read: 9600)
            XCTAssertEqual(p.triggerKeys, typeless ? [.function, .function, .function, .function]
                                                  : [.rightCommand, .rightCommand])
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertEqual(p.switchCount, 1)
            XCTAssertFalse(p.capture)
            XCTAssertFalse(p.shortcut.isBusy)
        }
    }

    @MainActor func testUnavailableAlternateLeavesSelectionUnchangedWithoutReturn() async {
        for target in VoiceTarget.allCases {
            let p = Pipeline(target)
            p.doubaoEnabled = false
            p.typelessRunning = false
            p.press(0)
            p.release(0.05)
            p.press(0.1)
            p.release(0.2)
            p.poll(1)
            XCTAssertEqual(p.target, target)
            XCTAssertEqual(p.switchCount, 0)
            XCTAssertEqual(p.rejectedSwitchCount, 1)
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertTrue(p.keys.isEmpty)
            XCTAssertFalse(p.capture)
        }
    }

    @MainActor func testDoubleTapDuringPreviousDrainDoesNotTruncateOrChangeItsTarget() async {
        let p = Pipeline(.typeless)
        p.press(0)
        p.poll(0.3)
        p.poll(0.32)
        p.poll(0.44)
        p.release(1)
        p.press(1.01)
        p.release(1.04)
        p.press(1.08)
        p.release(1.12)
        XCTAssertEqual(p.voice.phase, .draining)
        XCTAssertTrue(p.capture)
        XCTAssertEqual(p.switchCount, 0)
        XCTAssertEqual(p.rejectedSwitchCount, 1)
        XCTAssertEqual(p.returnCount, 0)
        XCTAssertEqual(p.triggerKeys, [.function, .function])
        p.poll(1.13, read: 9600)
        p.poll(1.25, read: 9600)
        XCTAssertEqual(p.target, .typeless)
        XCTAssertEqual(p.triggerKeys, [.function, .function, .function, .function])
        XCTAssertFalse(p.capture)
        XCTAssertFalse(p.shortcut.isBusy)
    }

    @MainActor func testCancelledPendingSingleTapNeverTypesAfterTeardown() async {
        for reason in ["disconnect", "sleep", "configuration", "permission", "exit"] {
            let p = Pipeline(.typeless)
            p.press(0)
            p.release(0.1)
            _ = p.gesture.cancelAll()
            p.apply(p.voice.abort(reason: reason))
            p.shortcut.shutdown()
            p.poll(2)
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertEqual(p.switchCount, 0)
            XCTAssertTrue(p.keys.isEmpty)
            XCTAssertFalse(p.capture)
        }
    }

    @MainActor func testTypelessStopsOnlyAfterTailAndDrainWithoutSwitchingInputSource() async {
        let p = Pipeline(.typeless)
        p.press(0)
        p.poll(0.3)
        p.poll(0.32)
        p.poll(0.44)
        XCTAssertEqual(p.keys, [true, false])
        XCTAssertEqual(p.voice.phase, .active)
        XCTAssertEqual(p.sourceSelections, 0)
        p.release(1)
        p.poll(1.08, write: 11000)
        p.poll(1.15, write: 11000)
        p.poll(1.17, write: 11000, read: 10000)
        XCTAssertEqual(p.keys, [true, false])
        XCTAssertTrue(p.capture)
        p.poll(1.2, write: 11000, read: 11000)
        XCTAssertEqual(p.keys, [true, false, true])
        XCTAssertFalse(p.capture)
        p.poll(1.32, write: 11000, read: 11000)
        XCTAssertEqual(p.keys, [true, false, true, false])
        XCTAssertEqual(p.triggerKeys, Array(repeating: .function, count: 4))
        XCTAssertNil(p.keyLatch.heldShortcut)
        XCTAssertFalse(p.shortcut.isBusy)
    }

    @MainActor func testDoubaoSelectsSourceOnceAndHoldsRightCommandUntilDrained() async {
        let p = Pipeline(.doubao)
        p.press(0)
        p.poll(0.3)
        p.poll(0.32)
        p.poll(0.4, write: 12000)
        XCTAssertEqual(p.sourceSelections, 1)
        XCTAssertEqual(p.keys, [true])
        p.release(1)
        p.poll(1.1, write: 12000, read: 12000)
        XCTAssertEqual(p.keys, [true, false])
        XCTAssertEqual(p.triggerKeys, [.rightCommand, .rightCommand])
        XCTAssertNil(p.keyLatch.heldShortcut)
        XCTAssertFalse(p.capture)
    }

    @MainActor func testDoubaoAbortReleasesOnlyRightCommand() async {
        for reason in ["disconnect", "sleep", "configuration", "permission", "capture failure"] {
            let p = Pipeline(.doubao)
            p.press(0)
            p.poll(0.3)
            p.poll(0.32)
            p.now = 0.4
            p.apply(p.voice.abort(reason: reason))
            p.shortcut.cancelAll(at: p.now)
            p.shortcut.shutdown()
            p.poll(1)
            XCTAssertEqual(p.keys, [true, false])
            XCTAssertEqual(p.triggerKeys, [.rightCommand, .rightCommand])
            XCTAssertNil(p.keyLatch.heldShortcut)
            XCTAssertFalse(p.capture)
        }
    }

    @MainActor func testAbortDuringStartDoesNotResurrectCaptureOrToggleAgain() async {
        for reason in ["disconnect", "sleep", "configuration", "permission", "capture failure"] {
            let p = Pipeline(.typeless)
            p.press(0)
            p.poll(0.3)
            p.poll(0.32)
            p.now = 0.33
            p.apply(p.voice.abort(reason: reason))
            p.shortcut.cancelAll(at: p.now)
            p.poll(0.44)
            p.poll(0.56)
            p.poll(1)
            XCTAssertEqual(p.keys, [true, false, true, false])
            XCTAssertEqual(p.voice.phase, .idle)
            XCTAssertFalse(p.capture)
            XCTAssertFalse(p.shortcut.isBusy)
        }
    }

    @MainActor func testVolumeChordsChooseStartModeButEndWithPlainFnAfterDrain() async {
        for (button, mode) in [(VoiceVolumeButton.up, TypelessVoiceMode.translate),
                                (.down, .askAnything)] {
            let p = Pipeline(.typeless)
            p.press(0)
            p.volume(button)
            p.poll(0.299)
            XCTAssertTrue(p.keys.isEmpty)
            p.poll(0.3)
            p.poll(0.32)
            p.poll(0.44)
            let chord = VoiceShortcut.typeless(mode).keys
            let startKeys = chord + chord.reversed()
            XCTAssertEqual(p.triggerKeys, startKeys)
            XCTAssertEqual(p.voice.typelessMode, mode)
            p.release(1)
            p.poll(1.1, read: 0)
            XCTAssertEqual(p.triggerKeys, startKeys) // no stop until the audio is consumed
            p.poll(1.2, read: 9600)
            p.poll(1.32, read: 9600)
            XCTAssertEqual(p.triggerKeys, startKeys + [.function, .function])
            XCTAssertFalse(p.capture)
            XCTAssertFalse(p.shortcut.isBusy)
            XCTAssertTrue(p.keyLatch.heldKeys.isEmpty)
            XCTAssertEqual(p.volumeCount, 0)
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertEqual(p.sourceSelections, 0)
        }
    }

    @MainActor func testShortChordCancelsWithoutReturnAndNextShortTapStillSends() async {
        for button in [VoiceVolumeButton.up, .down] {
            let p = Pipeline(.typeless)
            p.press(0)
            p.volume(button)
            p.release(0.299)
            p.poll(2)
            XCTAssertTrue(p.keys.isEmpty)
            XCTAssertEqual(p.returnCount, 0)
            XCTAssertEqual(p.volumeCount, 0)
            XCTAssertFalse(p.capture)
            p.press(3)
            p.release(3.1)
            XCTAssertEqual(p.returnCount, 0)
            p.poll(3.4)
            XCTAssertEqual(p.returnCount, 1)
        }
    }

    @MainActor func testVolumeKeepsItsNormalFunctionOutsideTypelessSiriHold() async {
        for target in VoiceTarget.allCases {
            let p = Pipeline(target)
            p.volume(.up)
            p.volume(.down)
            XCTAssertEqual(p.volumeCount, 2)
            p.press(0)
            p.volume(.up)
            p.volume(.down)
            XCTAssertEqual(p.volumeCount, target == .doubao ? 4 : 2)
            XCTAssertEqual(p.voice.typelessMode, target == .doubao ? .dictate : .askAnything)
            p.release(0.1)
            p.volume(.up)
            XCTAssertEqual(p.volumeCount, target == .doubao ? 5 : 3)
        }
    }

    @MainActor func testSystemVolumeChordIsConsumedBeforeAfterOrWithoutHIDCopy() async {
        for button in [VoiceVolumeButton.up, .down] {
            for delivery in ["NX first", "HID first", "NX only"] {
                let p = Pipeline(.typeless)
                p.press(0)
                if delivery == "HID first" { p.volume(button) }
                // No recent-HID predicate: voice ownership must work independently of it.
                XCTAssertTrue(p.systemVolume(button), delivery)
                if delivery == "NX first" { p.volume(button) }
                p.poll(0.3)
                p.poll(0.32)
                p.poll(0.44)
                XCTAssertEqual(p.voice.typelessMode, button == .up ? .translate : .askAnything)
                p.release(1)
                // Still-held volume repeats and the final up must not escape after Siri-up,
                // including after the old 300 ms timestamp window would have elapsed.
                p.poll(1.1, read: 9600)
                p.poll(1.22, read: 9600)
                XCTAssertTrue(p.systemVolume(button, repeatKey: true))
                XCTAssertTrue(p.systemVolume(button, down: false))
                XCTAssertEqual(p.volumeCount, 0, delivery)
                XCTAssertEqual(p.returnCount, 0)
                XCTAssertFalse(p.systemVolume(button)) // next ordinary press works
                XCTAssertEqual(p.volumeCount, 1)
            }
        }
    }

    @MainActor func testNativeVolumeOutsideTypelessHoldIsNotIntercepted() async {
        for target in VoiceTarget.allCases {
            let p = Pipeline(target)
            XCTAssertFalse(p.systemVolume(.up))
            XCTAssertFalse(p.systemVolume(.up, down: false))
            XCTAssertEqual(p.volumeCount, 1)
            p.press(0)
            XCTAssertEqual(p.systemVolume(.down), target == .typeless)
            XCTAssertEqual(p.systemVolume(.down, down: false), target == .typeless)
            XCTAssertEqual(p.volumeCount, target == .typeless ? 1 : 2)
        }
    }

    @MainActor func testModeLocksAtStartAndNextSessionDefaultsToDictate() async {
        let p = Pipeline(.typeless)
        p.press(0)
        p.volume(.up)
        p.volume(.down) // last choice wins only while preparing
        p.poll(0.3)
        p.poll(0.32)
        p.volume(.up) // too late: start chord is already in flight
        p.poll(0.44)
        p.volume(.up) // no mid-recording toggle, no volume side effect
        XCTAssertEqual(p.voice.typelessMode, .askAnything)
        XCTAssertEqual(p.triggerKeys, [.function, .space, .space, .function])
        p.release(1)
        p.poll(1.1, read: 9600)
        p.poll(1.22, read: 9600)
        p.press(2)
        p.poll(2.3)
        p.poll(2.32)
        p.poll(2.44)
        XCTAssertEqual(p.voice.typelessMode, .dictate)
        XCTAssertEqual(Array(p.triggerKeys.suffix(2)), [.function, .function])
        XCTAssertEqual(p.volumeCount, 0)
    }

    @MainActor func testPendingModeDuringDrainBelongsToTheFollowingPhysicalPress() async {
        let p = Pipeline(.typeless)
        p.press(0)
        p.volume(.up)
        p.poll(0.3)
        p.poll(0.32)
        p.poll(0.44)
        p.release(1)
        p.press(1.01)
        p.volume(.down)
        XCTAssertEqual(p.voice.typelessMode, .translate)
        p.poll(1.1, read: 9600)
        XCTAssertEqual(p.voice.typelessMode, .askAnything)
        p.poll(1.22)
        p.poll(1.31)
        p.poll(1.33)
        p.poll(1.45)
        XCTAssertEqual(Array(p.triggerKeys.suffix(4)), [.function, .space, .space, .function])
        XCTAssertEqual(p.volumeCount, 0)
        XCTAssertEqual(p.voice.phase, .active)
    }

    @MainActor func testCancelledPendingChordCannotLeakIntoNextSession() async {
        let p = Pipeline(.typeless)
        p.press(0)
        p.poll(0.3)
        p.poll(0.32)
        p.poll(0.44)
        p.release(1)
        p.press(1.01)
        p.volume(.up)
        p.release(1.1)
        p.poll(1.2, read: 9600)
        p.poll(1.32, read: 9600)
        XCTAssertEqual(p.returnCount, 0)
        XCTAssertEqual(p.triggerKeys, Array(repeating: .function, count: 4))
        p.press(2)
        XCTAssertEqual(p.voice.typelessMode, .dictate)
    }

    @MainActor func testChordTeardownPairsAllKeysAcrossStartRecordAndDrain() async {
        for mode in [TypelessVoiceMode.translate, .askAnything] {
            for abortAt in [0.1, 0.33, 0.5, 1.01] {
                let p = Pipeline(.typeless)
                p.press(0)
                p.volume(mode == .translate ? .up : .down)
                if abortAt >= 0.3 { p.poll(0.3); p.poll(0.32) }
                if abortAt >= 0.44 { p.poll(0.44) }
                if abortAt >= 1 { p.release(1) }
                p.now = abortAt
                _ = p.gesture.cancelAll()
                p.apply(p.voice.abort(reason: "teardown"))
                p.shortcut.cancelAll(at: p.now)
                p.shortcut.shutdown()
                p.poll(2)
                for key in [VoiceTriggerKey.function, .leftShift, .space] {
                    let edges = zip(p.triggerKeys, p.keys).filter { $0.0 == key }.map { $0.1 }
                    XCTAssertEqual(edges.filter { $0 }.count, edges.filter { !$0 }.count)
                }
                XCTAssertEqual(p.voice.typelessMode, .dictate)
                XCTAssertNil(p.keyLatch.heldShortcut)
                XCTAssertTrue(p.keyLatch.heldKeys.isEmpty)
                XCTAssertFalse(p.capture)
                XCTAssertFalse(p.shortcut.isBusy)
                XCTAssertEqual(p.returnCount, 0)
            }
        }
    }
}
