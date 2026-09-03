import XCTest
@testable import SiriRemoteCore

final class InputPoliciesTests: XCTestCase {
    func testAllTouchAndCircularSwitchCombinations() {
        for touch in [false, true] {
            for circular in [false, true] {
                let policy = TouchFeaturePolicy(
                    touchEnabled: touch,
                    circularScrollEnabled: circular
                )
                XCTAssertEqual(policy.permits(.pointerOrGesture), touch)
                XCTAssertEqual(policy.permits(.circularScroll), circular)
                XCTAssertTrue(policy.permits(.physicalButton))
            }
        }
    }

    func testHeldInputLatchRequiresExactlyOneEdgePerStateChange() {
        var latch = HeldInputLatch()
        XCTAssertTrue(latch.needsTransition(to: true))
        latch.commit(true)
        XCTAssertFalse(latch.needsTransition(to: true))
        XCTAssertTrue(latch.needsTransition(to: false))
        latch.commit(false)
        XCTAssertFalse(latch.needsTransition(to: false))
    }

    func testSyntheticMouseButtonLatchPairsAndCancelsExactlyOnce() {
        var latch = SyntheticMouseButtonLatch()
        XCTAssertTrue(latch.beginDown())
        XCTAssertFalse(latch.beginDown())
        XCTAssertTrue(latch.isDown)
        XCTAssertTrue(latch.endUp())
        XCTAssertFalse(latch.endUp())
        XCTAssertFalse(latch.isDown)
    }

    func testPermissionEdgesRebuildOnlyTheirOwnedSubsystem() {
        var policy = PermissionRecoveryPolicy(initial: PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: true
        ))

        XCTAssertEqual(policy.update(PermissionGrantState(
            accessibilityGranted: false,
            hidInputAvailable: true
        )), [.stopAccessibilityInput])
        XCTAssertEqual(policy.update(PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: true
        )), [.startAccessibilityInput])
        XCTAssertEqual(policy.update(PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: false
        )), [.stopHIDInput])
        XCTAssertEqual(policy.update(PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: true
        )), [.startHIDInput])
    }

    func testAccessibilityRecoveryRelaunchesOnceWhenHIDAuthorizationIsStale() {
        var policy = PermissionRecoveryPolicy(initial: PermissionGrantState(
            accessibilityGranted: false,
            hidInputAvailable: false
        ))
        let recoveredAccessibilityOnly = PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: false
        )

        XCTAssertEqual(policy.update(recoveredAccessibilityOnly), [
            .startAccessibilityInput,
            .relaunchForStaleHIDAuthorization,
        ])
        XCTAssertEqual(policy.update(recoveredAccessibilityOnly), [])
    }

    func testSimultaneousPermissionRecoveryNeedsNoRelaunch() {
        var policy = PermissionRecoveryPolicy(initial: PermissionGrantState(
            accessibilityGranted: false,
            hidInputAvailable: false
        ))

        XCTAssertEqual(policy.update(PermissionGrantState(
            accessibilityGranted: true,
            hidInputAvailable: true
        )), [
            .startAccessibilityInput,
            .startHIDInput,
        ])
    }
}
