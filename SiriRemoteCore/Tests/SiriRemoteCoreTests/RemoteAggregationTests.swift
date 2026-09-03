import XCTest
@testable import SiriRemoteCore

final class RemoteAggregationTests: XCTestCase {
    func testInterfaceRegistryIsIdempotentAndDisconnectsOnlyAtZero() {
        var registry = RemoteInterfaceRegistry<String>()
        XCTAssertTrue(registry.add("buttons"))
        XCTAssertFalse(registry.add("buttons"))
        XCTAssertTrue(registry.add("audio"))
        XCTAssertEqual(registry.count, 2)
        XCTAssertTrue(registry.remove("buttons"))
        XCTAssertTrue(registry.isConnected)
        XCTAssertTrue(registry.remove("audio"))
        XCTAssertFalse(registry.isConnected)
    }

    func testMirroredButtonEdgesProduceOneLogicalPair() {
        var state = MultiRemoteButtonState<String, String>()
        XCTAssertEqual(state.update(source: "a", button: "menu", pressed: true), .globalDown)
        XCTAssertEqual(state.update(source: "b", button: "menu", pressed: true), .sourceOnly)
        XCTAssertEqual(state.update(source: "a", button: "menu", pressed: false), .sourceOnly)
        XCTAssertEqual(state.update(source: "b", button: "menu", pressed: false), .globalUp)
    }

    func testDuplicateAndSingleInterfaceRemovalDoNotInventRelease() {
        var state = MultiRemoteButtonState<String, String>()
        _ = state.update(source: "a", button: "siri", pressed: true)
        XCTAssertEqual(state.update(source: "a", button: "siri", pressed: true), .duplicate)
        _ = state.update(source: "b", button: "siri", pressed: true)
        XCTAssertTrue(state.removeSource("a").isEmpty)
        XCTAssertEqual(state.removeSource("b"), ["siri"])
    }

    func testRemovingOneInterfaceReleasesOnlyButtonsOwnedByThatInterface() {
        var state = MultiRemoteButtonState<String, String>()
        XCTAssertEqual(state.update(source: "buttons", button: "menu", pressed: true), .globalDown)
        XCTAssertEqual(state.update(source: "media", button: "tv", pressed: true), .globalDown)

        XCTAssertEqual(state.removeSource("buttons"), ["menu"])
        XCTAssertFalse(state.isPressed("menu"))
        XCTAssertTrue(state.isPressed("tv"))
        XCTAssertEqual(state.removeSource("media"), ["tv"])
    }
}
