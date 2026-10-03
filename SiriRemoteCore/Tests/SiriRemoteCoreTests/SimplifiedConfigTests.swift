import XCTest
@testable import SiriRemoteCore

final class SimplifiedConfigTests: XCTestCase {
    private let minimal = """
    {
      "settings": { "touchEnabled": true }
    }
    """

    func testSettingsOnlyConfigLoadsDefaults() throws {
        let config = try ConfigLoader.load(minimal)
        XCTAssertTrue(config.settings.touchEnabled)
        XCTAssertTrue(config.settings.circularScroll.enabled)
        XCTAssertEqual(config.settings.cursorSpeed, 0.6)
        XCTAssertEqual(config.settings.voiceTarget, .doubao)
    }

    func testRoundTripKeepsSettingsOnlySchema() throws {
        let original = try ConfigLoader.load(minimal)
        let serialized = try ConfigWriter.serialize(original)
        XCTAssertEqual(try ConfigLoader.load(serialized), original)
        XCTAssertFalse(serialized.contains("modes"))
        XCTAssertFalse(serialized.contains("appProfiles"))
        XCTAssertFalse(serialized.contains("doubaoInputSourceID"))
    }

    func testRetiredSchemasAreRejected() {
        for field in ["modes", "appProfiles"] {
            XCTAssertThrowsError(try ConfigLoader.load("""
            { "settings": {}, "\(field)": {} }
            """)) { error in
                XCTAssertTrue(error.localizedDescription.contains(field))
            }
        }

        for field in ["defaultMode", "doubaoInputSourceID", "holdThreshold", "doubleTapWindow"] {
            XCTAssertThrowsError(try ConfigLoader.load("""
            { "settings": { "\(field)": 1 } }
            """)) { error in
                XCTAssertTrue(error.localizedDescription.contains(field))
            }
        }
    }

    func testSettingsRangesAreValidated() {
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "cursorSpeed": 4.0 } }
        """))
        XCTAssertThrowsError(try ConfigLoader.load("""
        {
          "settings": {
            "circularScroll": { "accelMin": 3.0, "accelMax": 2.0 }
          }
        }
        """))
    }

    func testSettingsEditsAreValueSemantic() throws {
        let original = try ConfigLoader.load(minimal)
        let changed = original.withSettingsUpdated { $0.touchEnabled = false }
        XCTAssertTrue(original.settings.touchEnabled)
        XCTAssertFalse(changed.settings.touchEnabled)
    }

    func testTypelessSelectionPersistsWithoutInputSourceSwitching() throws {
        let config = try ConfigLoader.load("""
        { "settings": { "voiceTarget": "typeless", "cursorSpeed": 1.0 } }
        """)
        XCTAssertEqual(config.settings.voiceTarget, .typeless)
        XCTAssertFalse(config.settings.voiceTarget.requiresInputSourceSelection)
        XCTAssertTrue(VoiceTarget.doubao.requiresInputSourceSelection)
        XCTAssertEqual(try ConfigLoader.load(ConfigWriter.serialize(config)), config)
        XCTAssertThrowsError(try ConfigLoader.load("""
        { "settings": { "voiceTarget": "unknown" } }
        """))
    }
}
