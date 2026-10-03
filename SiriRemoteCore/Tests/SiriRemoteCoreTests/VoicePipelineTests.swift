import XCTest
@testable import SiriRemoteCore

/// Exercises the production lifecycle, shortcut controller and key latch, with OS effects replaced.
final class VoicePipelineTests: XCTestCase {
    @MainActor
    private final class Pipeline {
        let target: VoiceTarget
        var now: TimeInterval = 0
        var voice = VoiceSession()
        var keys: [Bool] = []
        var triggerKeys: [VoiceTriggerKey] = []
        var sourceSelections = 0
        var capture = false
        lazy var keyLatch = VoiceKeyLatch { [unowned self] key, down in
            keys.append(down)
            triggerKeys.append(key)
            return true
        }
        lazy var shortcut = VoiceShortcutController(
            setKey: { [unowned self] target, down in
                down ? keyLatch.press(target.triggerKey) : keyLatch.release()
            },
            onStarted: { [unowned self] id, success in
                apply(voice.recognitionStarted(session: id, at: now, success: success))
            },
            onStopFailure: { XCTFail("Unexpected stop failure") }
        )

        init(_ target: VoiceTarget) { self.target = target }

        func press(_ time: TimeInterval) { now = time; apply(voice.press(at: time)) }
        func release(_ time: TimeInterval) { now = time; apply(voice.release(at: time)) }
        func poll(_ time: TimeInterval, write: UInt64 = 9600, read: UInt64 = 0) {
            now = time
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
                    shortcut.start(session: id, target: target, at: now)
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
        XCTAssertNil(p.keyLatch.heldKey)
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
        XCTAssertNil(p.keyLatch.heldKey)
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
            XCTAssertNil(p.keyLatch.heldKey)
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
}
