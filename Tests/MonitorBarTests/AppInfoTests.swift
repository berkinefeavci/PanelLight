import XCTest
@testable import MonitorBar

final class AppInfoTests: XCTestCase {
    func testVersionTextShowsVersionAndBuild() {
        XCTAssertEqual(AppInfo.versionText(short: "0.2.0", build: "11"), "Version 0.2.0 (11)")
        XCTAssertEqual(AppInfo.versionText(short: "0.2.0", build: nil), "Version 0.2.0")
        XCTAssertNil(AppInfo.versionText(short: nil, build: "11"))
        XCTAssertNil(AppInfo.versionText(short: "", build: "11"))
    }
}
