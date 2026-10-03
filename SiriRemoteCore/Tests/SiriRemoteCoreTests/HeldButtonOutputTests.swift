import XCTest
@testable import SiriRemoteCore

final class HeldButtonOutputTests: XCTestCase {
    func testRepeatsKeepOneDownUpPairForEveryRepeatingButton() {
        for button in FixedRemoteButton.allCases where button.repeatsWhileHeld {
            var edges: [HeldButtonEdge] = []
            let output = HeldButtonOutput { actual, edge in
                XCTAssertEqual(actual, button)
                edges.append(edge)
                return true
            }
            var state = FixedButtonHoldState()
            func apply(_ commands: [FixedButtonHoldState.Command]) {
                for command in commands {
                    switch command {
                    case .beginHold(let key): output.begin(key)
                    case .repeatHold(let key): output.repeatDown(key)
                    case .endHold(let key): output.end(key)
                    case .activate: XCTFail("Held button must not emit a tap")
                    }
                }
            }
            let timing = ButtonRepeatTiming(delay: 0.5, interval: 0.1)!
            apply(state.press(button, at: 0, timing: timing))
            apply(state.takeRepeats(at: 0.5))
            apply(state.takeRepeats(at: 0.6))
            XCTAssertEqual(edges, [.down, .repeatDown, .repeatDown])
            apply(state.release(button, at: 0.7))
            apply(state.takeRepeats(at: 1))
            apply(state.reset())
            output.releaseAll()
            XCTAssertEqual(edges, [.down, .repeatDown, .repeatDown, .up])
            XCTAssertTrue(output.heldButtons.isEmpty)
        }
    }

    func testOwnedDownAndUpAreIdempotent() {
        var edges: [HeldButtonEdge] = []
        let output = HeldButtonOutput { _, edge in edges.append(edge); return true }
        XCTAssertFalse(output.repeatDown(.ringRight))
        XCTAssertTrue(output.end(.ringRight)) // no unrelated key-up
        XCTAssertTrue(output.begin(.ringRight))
        XCTAssertTrue(output.begin(.ringRight))
        XCTAssertTrue(output.repeatDown(.ringRight))
        XCTAssertTrue(output.end(.ringRight))
        XCTAssertTrue(output.end(.ringRight))
        XCTAssertFalse(output.repeatDown(.ringRight))
        XCTAssertEqual(edges, [.down, .repeatDown, .up])
    }

    func testFailedDownDoesNotAcquireOwnershipOrRepeat() {
        var edges: [HeldButtonEdge] = []
        let output = HeldButtonOutput { _, edge in edges.append(edge); return false }
        XCTAssertFalse(output.begin(.menu))
        XCTAssertFalse(output.repeatDown(.menu))
        output.releaseAll()
        XCTAssertEqual(edges, [.down])
        XCTAssertTrue(output.heldButtons.isEmpty)
    }

    func testTeardownAttemptsEveryOwnedReleaseEvenIfOneFails() {
        var released: [FixedRemoteButton] = []
        let output = HeldButtonOutput { button, edge in
            if edge == .up { released.append(button); return button != .menu }
            return true
        }
        output.begin(.menu)
        output.begin(.ringRight)
        output.begin(.volumeUp)
        output.releaseAll()
        XCTAssertEqual(Set(released), [.menu, .ringRight, .volumeUp])
        XCTAssertTrue(output.heldButtons.isEmpty)
        output.releaseAll()
        XCTAssertEqual(released.count, 3)
    }

    func testContextOrVoiceChordCancellationEndsExistingHoldWithoutRestartingIt() {
        for button in [FixedRemoteButton.ringRight, .volumeUp, .volumeDown] {
            var edges: [HeldButtonEdge] = []
            let output = HeldButtonOutput { _, edge in edges.append(edge); return true }
            var state = FixedButtonHoldState()
            _ = state.press(button, at: 0, timing: ButtonRepeatTiming(delay: 0.5, interval: 0.1))
            output.begin(button)
            state.consumeUntilRelease(button)
            output.end(button)
            XCTAssertEqual(state.takeRepeats(at: 60), [])
            XCTAssertFalse(output.repeatDown(button))
            state.release(button, at: 61)
            output.end(button)
            XCTAssertEqual(edges, [.down, .up])
        }
    }

    func testRepeatFlagsDescribeContinuousDownEvents() {
        XCTAssertTrue(HeldButtonEdge.down.isDown)
        XCTAssertFalse(HeldButtonEdge.down.isRepeat)
        XCTAssertTrue(HeldButtonEdge.repeatDown.isDown)
        XCTAssertTrue(HeldButtonEdge.repeatDown.isRepeat)
        XCTAssertFalse(HeldButtonEdge.up.isDown)
        XCTAssertFalse(HeldButtonEdge.up.isRepeat)
    }
}
