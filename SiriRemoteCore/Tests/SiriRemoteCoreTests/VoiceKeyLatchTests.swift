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
        let doubao = VoiceTarget.doubao.triggerKey
        let typeless = VoiceTarget.typeless.triggerKey
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
    }

    @MainActor func testDuplicatePressAndReleaseAreIdempotent() async {
        for target in VoiceTarget.allCases {
            var edges: [Edge] = []
            let latch = VoiceKeyLatch { key, down in edges.append(Edge(key, down)); return true }
            XCTAssertTrue(latch.press(target.triggerKey))
            XCTAssertTrue(latch.press(target.triggerKey))
            XCTAssertEqual(latch.heldKey, target.triggerKey)
            XCTAssertTrue(latch.release())
            XCTAssertTrue(latch.release())
            XCTAssertEqual(edges, [Edge(target.triggerKey, true), Edge(target.triggerKey, false)])
            XCTAssertNil(latch.heldKey)
        }
    }

    @MainActor func testAnotherKeyCannotReplaceHeldKey() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { key, down in edges.append(Edge(key, down)); return true }
        XCTAssertTrue(latch.press(.rightCommand))
        XCTAssertFalse(latch.press(.function))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true), Edge(.rightCommand, false)])
        XCTAssertTrue(latch.press(.function))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges.suffix(2), [Edge(.function, true), Edge(.function, false)])
    }

    @MainActor func testFailedDownNeverOwnsARelease() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { key, down in edges.append(Edge(key, down)); return false }
        XCTAssertFalse(latch.press(.rightCommand))
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true)])
        XCTAssertNil(latch.heldKey)
    }

    @MainActor func testFailedUpClearsInternalOwnership() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { key, down in edges.append(Edge(key, down)); return down }
        XCTAssertTrue(latch.press(.rightCommand))
        XCTAssertFalse(latch.release())
        XCTAssertTrue(latch.release())
        XCTAssertEqual(edges, [Edge(.rightCommand, true), Edge(.rightCommand, false)])
        XCTAssertNil(latch.heldKey)
    }

    @MainActor func testTargetSwitchAndShutdownReleaseTheOriginalKey() async {
        var edges: [Edge] = []
        let latch = VoiceKeyLatch { key, down in edges.append(Edge(key, down)); return true }
        let shortcut = VoiceShortcutController(
            setKey: { target, down in down ? latch.press(target.triggerKey) : latch.release() },
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
        XCTAssertNil(latch.heldKey)
        XCTAssertFalse(shortcut.isBusy)
    }
}
