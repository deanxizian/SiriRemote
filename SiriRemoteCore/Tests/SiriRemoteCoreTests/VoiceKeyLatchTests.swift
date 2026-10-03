import Carbon
import CoreGraphics
import IOKit.hidsystem
import XCTest
@testable import SiriRemoteCore

final class VoiceKeyLatchTests: XCTestCase {
    private struct Edge: Equatable {
        let key: VoiceTriggerKey
        let down: Bool
        init(_ key: VoiceTriggerKey, _ down: Bool) { self.key = key; self.down = down }
    }

    func testTargetKeyCodesAndFlagsMatchMacOSHeaders() {
        let doubao = VoiceShortcut.doubao.keys[0]
        let typeless = VoiceShortcut.typeless(.dictate).keys[0]
        XCTAssertEqual(doubao, .rightCommand)
        XCTAssertEqual(doubao.keyCode, UInt16(kVK_RightCommand))
        XCTAssertEqual(doubao.downFlagsRawValue,
                       CGEventFlags.maskCommand.rawValue | UInt64(NX_DEVICERCMDKEYMASK))
        XCTAssertEqual(doubao.downFlagsRawValue & CGEventFlags.maskSecondaryFn.rawValue, 0)
        // Right Option belongs to Doubao's hands-free mode, never our hold-to-talk path.
        XCTAssertNotEqual(doubao.keyCode, UInt16(kVK_RightOption))
        XCTAssertEqual(doubao.downFlagsRawValue & CGEventFlags.maskAlternate.rawValue, 0)
        XCTAssertEqual(typeless, .function)
        XCTAssertEqual(typeless.keyCode, UInt16(kVK_Function))
        XCTAssertEqual(typeless.downFlagsRawValue, CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(VoiceTriggerKey.leftShift.keyCode, UInt16(kVK_Shift))
        XCTAssertEqual(VoiceTriggerKey.leftShift.downFlagsRawValue,
                       CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK))
        XCTAssertEqual(VoiceTriggerKey.space.keyCode, UInt16(kVK_Space))
        XCTAssertEqual(VoiceTriggerKey.space.downFlagsRawValue, 0)
    }

    @MainActor func testDuplicatePressAndReleaseAreIdempotent() async {
        for target in VoiceTarget.allCases {
            let shortcut = VoiceShortcut(target: target)
            let key = shortcut.keys[0]
            var edges: [Edge] = []
            let latch = VoiceKeyLatch { edge in edges.append(Edge(edge.key, edge.isDown)); return true }
            XCTAssertTrue(latch.press(shortcut))
            XCTAssertTrue(latch.press(shortcut))
            XCTAssertEqual(latch.heldShortcut, shortcut)
            XCTAssertTrue(latch.release())
            XCTAssertTrue(latch.release())
            XCTAssertEqual(edges, [Edge(key, true), Edge(key, false)])
            XCTAssertNil(latch.heldShortcut)
            XCTAssertTrue(latch.heldKeys.isEmpty)
        }
    }

    @MainActor func testAnotherKeyCannotReplaceHeldKey() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { edge in edges.append(Edge(edge.key, edge.isDown)); return true }
        XCTAssertTrue(latch.press(.doubao))
        XCTAssertFalse(latch.press(.typeless(.dictate)))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true), Edge(.rightCommand, false)])
        XCTAssertTrue(latch.press(.typeless(.dictate)))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges.suffix(2), [Edge(.function, true), Edge(.function, false)])
    }

    @MainActor func testFailedDownNeverOwnsARelease() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { edge in edges.append(Edge(edge.key, edge.isDown)); return false }
        XCTAssertFalse(latch.press(.doubao))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true)])
        XCTAssertNil(latch.heldShortcut)
    }

    @MainActor func testFailedUpClearsInternalOwnership() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { edge in edges.append(Edge(edge.key, edge.isDown)); return edge.isDown }
        XCTAssertTrue(latch.press(.doubao))
        XCTAssertFalse(latch.release())
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true), Edge(.rightCommand, false)])
        XCTAssertNil(latch.heldShortcut)
    }

    @MainActor func testTargetSwitchAndShutdownReleaseTheOriginalKey() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { edge in edges.append(Edge(edge.key, edge.isDown)); return true }
        let shortcut = VoiceShortcutController(
            setShortcut: { shortcut, down in down ? latch.press(shortcut) : latch.release() },
            onStarted: { _, success in XCTAssertTrue(success) },
            onStopFailure: { XCTFail("Unexpected stop failure") }
        )
        shortcut.start(session: 1, target: .doubao, at: 0)
        shortcut.cancelAll(at: 1)
        shortcut.start(session: 2, target: .typeless, at: 1)
        shortcut.poll(at: 1.12)
        shortcut.end(session: 2, at: 2)
        shortcut.start(session: 3, target: .doubao, at: 2.01)
        shortcut.poll(at: 2.12)
        shortcut.shutdown()
        shortcut.shutdown()
        XCTAssertEqual(edges, [Edge(.rightCommand, true), Edge(.rightCommand, false),
                               Edge(.function, true), Edge(.function, false),
                               Edge(.function, true), Edge(.function, false),
                               Edge(.rightCommand, true), Edge(.rightCommand, false)])
        XCTAssertNil(latch.heldShortcut)
        XCTAssertFalse(shortcut.isBusy)
    }

    @MainActor func testChordsPreserveModifierFlagsAndReleaseInReverseOrder() async {
        let shift = VoiceTriggerKey.leftShift.downFlagsRawValue
        let fn = VoiceTriggerKey.function.downFlagsRawValue
        let expectations: [(TypelessVoiceMode, [VoiceKeyEvent])] = [
            (.translate, [
                .init(key: .leftShift, isDown: true, flags: shift),
                .init(key: .function, isDown: true, flags: shift | fn),
                .init(key: .function, isDown: false, flags: shift),
                .init(key: .leftShift, isDown: false, flags: 0)
            ]),
            (.askAnything, [
                .init(key: .function, isDown: true, flags: fn),
                .init(key: .space, isDown: true, flags: fn),
                .init(key: .space, isDown: false, flags: fn),
                .init(key: .function, isDown: false, flags: 0)
            ])
        ]
        for (mode, expected) in expectations {
            var events: [VoiceKeyEvent] = []
            let latch = VoiceKeyLatch { events.append($0); return true }
            XCTAssertTrue(latch.press(.typeless(mode)))
            XCTAssertTrue(latch.press(.typeless(mode)))
            XCTAssertTrue(latch.release())
            XCTAssertTrue(latch.release())
            XCTAssertEqual(events, expected)
            XCTAssertTrue(latch.heldKeys.isEmpty)
            XCTAssertNil(latch.heldShortcut)
        }
    }

    @MainActor func testPartialChordFailureReleasesOnlySuccessfullyPressedKeys() async {
        for mode in [TypelessVoiceMode.translate, .askAnything] {
            var events: [VoiceKeyEvent] = []
            let keys = VoiceShortcut.typeless(mode).keys
            let latch = VoiceKeyLatch { edge in
                events.append(edge)
                return !edge.isDown || edge.key != keys[1]
            }
            XCTAssertFalse(latch.press(.typeless(mode)))
            XCTAssertEqual(events.map(\.key), [keys[0], keys[1], keys[0]])
            XCTAssertEqual(events.map(\.isDown), [true, true, false])
            XCTAssertEqual(events.last?.flags, 0)
            XCTAssertNil(latch.heldShortcut)
            XCTAssertTrue(latch.heldKeys.isEmpty)
            XCTAssertTrue(latch.release())
            XCTAssertEqual(events.count, 3)
        }
    }

    @MainActor func testFailedChordReleaseStillAttemptsEveryOwnedKey() async {
        var events: [VoiceKeyEvent] = []
        let latch = VoiceKeyLatch { edge in events.append(edge); return edge.isDown }
        XCTAssertTrue(latch.press(.typeless(.askAnything)))
        XCTAssertFalse(latch.release())
        XCTAssertEqual(events.map(\.key), [.function, .space, .space, .function])
        XCTAssertEqual(events.map(\.isDown), [true, true, false, false])
        XCTAssertEqual(events.last?.flags, 0)
        XCTAssertNil(latch.heldShortcut)
        XCTAssertTrue(latch.heldKeys.isEmpty)
    }
}
