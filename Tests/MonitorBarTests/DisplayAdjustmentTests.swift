import XCTest
@testable import MonitorBar

final class DisplayAdjustmentTests: XCTestCase {
    func testContrastUsesNeutralMidpointAndPreservesChannelValues() {
        let original: [Float] = [0, 0.25, 0.5, 0.75, 1]
        XCTAssertEqual(adjustedContrastTable(original, percent: 50), original)
        XCTAssertEqual(adjustedContrastTable(original, percent: 0), [0.25, 0.375, 0.5, 0.625, 0.75])
        XCTAssertEqual(adjustedContrastTable(original, percent: 100), [0, 0.125, 0.5, 0.875, 1])
    }
}

final class VersionTextTests: XCTestCase {
    func testVersionTextShowsVersionAndBuild() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "11"]
        XCTAssertEqual(appVersionText(info), "PanelLight 0.2.0 (11)")
    }

    func testVersionTextIsEmptyWithoutBundleInfo() {
        XCTAssertNil(appVersionText(nil))
        XCTAssertNil(appVersionText([:]))
    }
}
