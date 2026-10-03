import XCTest
@testable import SiriRemoteCore

final class VoiceShortcutControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        var keys: [Bool] = []
        var targets: [VoiceTarget] = []
        var started: [UInt64] = []
        var failed: [UInt64] = []
        var stopFailures = 0
        var allowDown = true
        var allowUp = true
        lazy var shortcut = VoiceShortcutController(
            setKey: { [unowned self] target, down in
                keys.append(down)
                targets.append(target)
                return down ? allowDown : allowUp
            },
            onStarted: { [unowned self] id, success in
                if success { started.append(id) } else { failed.append(id) }
            },
            onStopFailure: { [unowned self] in stopFailures += 1 }
        )
    }

    @MainActor func testDoubaoRetainsOneHeldDownUpPair() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .doubao, at: 0)
        h.shortcut.start(session: 1, target: .doubao, at: 0.1)
        h.shortcut.poll(at: 10)
        XCTAssertEqual(h.keys, [true])
        XCTAssertEqual(h.started, [1])
        h.shortcut.end(session: 1, at: 10)
        h.shortcut.end(session: 1, at: 10.1)
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testTypelessUsesExactlyTwo120MillisecondTaps() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 5)
        h.shortcut.poll(at: 5.119)
        XCTAssertEqual(h.keys, [true])
        XCTAssertTrue(h.started.isEmpty)
        h.shortcut.poll(at: 5.12)
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertEqual(h.started, [1])
        h.shortcut.poll(at: 8)
        XCTAssertEqual(h.keys, [true, false])
        h.shortcut.end(session: 1, at: 8)
        h.shortcut.end(session: 1, at: 8.01)
        h.shortcut.poll(at: 8.119)
        XCTAssertEqual(h.keys, [true, false, true])
        h.shortcut.poll(at: 8.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testCancellationDuringStartStillClosesToggleOnce() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.cancelAll(at: 0.01)
        h.shortcut.poll(at: 0.12)
        XCTAssertEqual(h.keys, [true, false, true])
        h.shortcut.cancelAll(at: 0.13)
        h.shortcut.poll(at: 0.24)
        h.shortcut.poll(at: 20)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testNextSessionWaitsForPreviousStopAndKeepsItsOwnTarget() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.poll(at: 0.12)
        h.shortcut.end(session: 1, at: 1)
        h.shortcut.start(session: 2, target: .doubao, at: 1.01)
        XCTAssertEqual(h.started, [1])
        h.shortcut.poll(at: 1.12)
        XCTAssertEqual(h.keys, [true, false, true, false, true])
        XCTAssertEqual(h.targets, [.typeless, .typeless, .typeless, .typeless, .doubao])
        XCTAssertEqual(h.started, [1, 2])
        h.shortcut.end(session: 1, at: 1.2) // stale stop must not release the new modifier
        h.shortcut.poll(at: 3)
        XCTAssertEqual(h.keys.count, 5)
        h.shortcut.end(session: 2, at: 3)
        XCTAssertEqual(h.keys.last, false)
    }

    @MainActor func testShortPendingSessionIsCancelledWithoutAStartTap() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.poll(at: 0.12)
        h.shortcut.end(session: 1, at: 1)
        h.shortcut.start(session: 2, target: .typeless, at: 1.01)
        h.shortcut.end(session: 2, at: 1.02)
        h.shortcut.poll(at: 1.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertEqual(h.started, [1])
        XCTAssertEqual(h.failed, [2])
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testDuplicateAndUnexpectedOverlappingStartCannotToggleOff() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.start(session: 1, target: .typeless, at: 0.01)
        h.shortcut.poll(at: 0.12)
        h.shortcut.start(session: 2, target: .typeless, at: 0.2)
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertEqual(h.failed, [2])
    }

    @MainActor func testFailedDownNeverSchedulesUpOrStopToggle() async {
        let h = Harness()
        h.allowDown = false
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.cancelAll(at: 1)
        h.shortcut.poll(at: 2)
        h.shortcut.shutdown()
        XCTAssertEqual(h.keys, [true])
        XCTAssertEqual(h.failed, [1])
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testPermissionOrTargetLossDuringStopDoesNotLeaveInternalLatch() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.poll(at: 0.12)
        h.allowDown = false
        h.shortcut.end(session: 1, at: 1)
        XCTAssertEqual(h.stopFailures, 1)
        XCTAssertFalse(h.shortcut.isBusy)
        h.shortcut.poll(at: 2)
        XCTAssertEqual(h.keys, [true, false, true])
    }

    @MainActor func testFailedStopReleaseRejectsQueuedSessionWithoutAnotherToggle() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.shortcut.poll(at: 0.12)
        h.shortcut.end(session: 1, at: 1)
        h.shortcut.start(session: 2, target: .typeless, at: 1.01)
        h.allowUp = false
        h.shortcut.poll(at: 1.12)
        XCTAssertEqual(h.keys, [true, false, true, false])
        XCTAssertEqual(h.started, [1])
        XCTAssertEqual(h.failed, [2])
        XCTAssertEqual(h.stopFailures, 1)
        XCTAssertFalse(h.shortcut.isBusy)
        h.shortcut.shutdown()
        h.shortcut.poll(at: 10)
        XCTAssertEqual(h.keys.count, 4)
    }

    @MainActor func testFailedStartReleaseDoesNotAssumeRecognizerStarted() async {
        let h = Harness()
        h.shortcut.start(session: 1, target: .typeless, at: 0)
        h.allowUp = false
        h.shortcut.poll(at: 0.12)
        h.shortcut.cancelAll(at: 0.2)
        h.shortcut.shutdown()
        XCTAssertEqual(h.keys, [true, false])
        XCTAssertEqual(h.failed, [1])
        XCTAssertTrue(h.started.isEmpty)
        XCTAssertFalse(h.shortcut.isBusy)
    }

    @MainActor func testShutdownFromEveryTogglePhaseCannotRestartRecording() async {
        for state in 0...3 {
            let h = Harness()
            if state > 0 { h.shortcut.start(session: 1, target: .typeless, at: 0) }
            if state > 1 { h.shortcut.poll(at: 0.12) }
            if state > 2 { h.shortcut.end(session: 1, at: 1) }
            h.shortcut.shutdown()
            h.shortcut.shutdown()
            h.shortcut.poll(at: 10)
            XCTAssertEqual(h.keys, state == 0 ? [] : [true, false, true, false])
            XCTAssertFalse(h.shortcut.isBusy)
        }
    }

    @MainActor func testReentrantEndAtStartAcknowledgementDoesNotDuplicateStop() async {
        var keys: [Bool] = []
        var shortcut: VoiceShortcutController!
        shortcut = VoiceShortcutController(
            setKey: { _, down in keys.append(down); return true },
            onStarted: { id, _ in shortcut.end(session: id, at: 0.12) },
            onStopFailure: { XCTFail("Unexpected stop failure") }
        )
        shortcut.start(session: 1, target: .typeless, at: 0)
        shortcut.end(session: 1, at: 0.01)
        shortcut.poll(at: 0.12)
        shortcut.poll(at: 0.24)
        XCTAssertEqual(keys, [true, false, true, false])
    }
}
