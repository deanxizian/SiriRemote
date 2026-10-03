import XCTest
@testable import SiriRemoteCore

final class MediaKeySuppressionTests: XCTestCase {
    func testChordTakesPriorityWithoutDependingOnRecentHID() {
        var policy = MediaKeySuppressionPolicy<String>()
        var calls = 0
        XCTAssertTrue(policy.shouldSuppress(
            "up", isDown: true, isRepeat: false, volumeButton: .up,
            handleVoiceChord: { button in
                calls += 1
                XCTAssertEqual(button, .up)
                return true
            },
            isDuplicateRemotePress: { XCTFail("Must not need HID history"); return false }
        ))
        for down in [true, true, false] {
            XCTAssertTrue(policy.shouldSuppress(
                "up", isDown: down, isRepeat: down, volumeButton: .up,
                handleVoiceChord: { _ in XCTFail("Already-owned edge"); return false },
                isDuplicateRemotePress: { XCTFail("Already-owned edge"); return false }
            ))
        }
        XCTAssertEqual(calls, 1)
    }

    func testLostReleaseCannotDisableNextOrdinaryPress() {
        var policy = MediaKeySuppressionPolicy<String>()
        XCTAssertTrue(policy.shouldSuppress(
            "up", isDown: true, isRepeat: false, volumeButton: .up,
            handleVoiceChord: { _ in true }, isDuplicateRemotePress: { false }
        ))
        // Missing up (e.g. HID seize) is self-healed by a fresh non-repeat down.
        for down in [true, false] {
            XCTAssertFalse(policy.shouldSuppress(
                "up", isDown: down, isRepeat: false, volumeButton: .up,
                handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
            ))
        }
    }

    func testNonVolumeAndUnownedEdgesPassWithoutVoiceHandling() {
        var policy = MediaKeySuppressionPolicy<String>()
        for down in [true, false] {
            XCTAssertFalse(policy.shouldSuppress(
                "play", isDown: down, isRepeat: false, volumeButton: nil,
                handleVoiceChord: { _ in XCTFail("Not a volume key"); return true },
                isDuplicateRemotePress: { false }
            ))
        }
    }

    func testDuplicateRemoteMediaKeepsExistingSuppressionAndOwnsItsRelease() {
        var policy = MediaKeySuppressionPolicy<String>()
        XCTAssertTrue(policy.shouldSuppress(
            "play", isDown: true, isRepeat: false, volumeButton: nil,
            handleVoiceChord: { _ in false }, isDuplicateRemotePress: { true }
        ))
        XCTAssertTrue(policy.shouldSuppress(
            "play", isDown: false, isRepeat: false, volumeButton: nil,
            handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
        ))
    }

    func testBothVolumeDirectionsAreTrackedIndependentlyAndResetOnStop() {
        var policy = MediaKeySuppressionPolicy<VoiceVolumeButton>()
        for button in [VoiceVolumeButton.up, .down] {
            XCTAssertTrue(policy.shouldSuppress(
                button, isDown: true, isRepeat: false, volumeButton: button,
                handleVoiceChord: { _ in true }, isDuplicateRemotePress: { false }
            ))
        }
        XCTAssertTrue(policy.shouldSuppress(
            .up, isDown: false, isRepeat: false, volumeButton: .up,
            handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
        ))
        XCTAssertTrue(policy.shouldSuppress(
            .down, isDown: true, isRepeat: true, volumeButton: .down,
            handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
        ))
        policy.reset()
        XCTAssertFalse(policy.shouldSuppress(
            .down, isDown: false, isRepeat: false, volumeButton: .down,
            handleVoiceChord: { _ in false }, isDuplicateRemotePress: { false }
        ))
    }
}
