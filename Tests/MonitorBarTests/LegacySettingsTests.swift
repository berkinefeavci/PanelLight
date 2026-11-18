import XCTest
@testable import MonitorBar

final class LegacySettingsTests: XCTestCase {
    func testRemovesOnlyKeysOfDeletedFeatures() throws {
        let suite = "PanelLightTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in LegacySettings.obsoleteKeys { defaults.set(1, forKey: key) }
        defaults.set(true, forKey: "linkBrightness")
        defaults.set("#3489FC", forKey: "externalBarColor")

        LegacySettings.removeObsoleteKeys(from: defaults)

        for key in LegacySettings.obsoleteKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertTrue(defaults.bool(forKey: "linkBrightness"))
        XCTAssertEqual(defaults.string(forKey: "externalBarColor"), "#3489FC")
        LegacySettings.removeObsoleteKeys(from: defaults)   // running it again changes nothing
        XCTAssertTrue(defaults.bool(forKey: "linkBrightness"))
    }
}
