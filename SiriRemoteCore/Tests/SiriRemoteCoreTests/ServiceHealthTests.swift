import XCTest
@testable import SiriRemoteCore

final class ServiceHealthTests: XCTestCase {
    func testMissingComponentsAreNeverReportedAsRunning() {
        XCTAssertEqual(
            InstalledServiceHealth.resolve(
                componentsInstalled: false,
                advertisedPID: 321,
                isProcessAlive: { _ in true }
            ),
            .notInstalled
        )
    }

    func testInstalledServiceWithoutLiveAdvertisementReportsFailure() {
        XCTAssertEqual(
            InstalledServiceHealth.resolve(
                componentsInstalled: true,
                advertisedPID: nil,
                isProcessAlive: { _ in true }
            ),
            .notRunning
        )
        XCTAssertEqual(
            InstalledServiceHealth.resolve(
                componentsInstalled: true,
                advertisedPID: 321,
                isProcessAlive: { _ in false }
            ),
            .notRunning
        )
    }

    func testInstalledServiceNeedsAConfirmedLivePID() {
        XCTAssertEqual(
            InstalledServiceHealth.resolve(
                componentsInstalled: true,
                advertisedPID: 321,
                isProcessAlive: { $0 == 321 }
            ),
            .running
        )
    }
}
