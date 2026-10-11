import AppKit
import XCTest
@testable import MonitorBar

final class SafetyTests: XCTestCase {
    func testEveryLinkIsHTTPSIntoTheProjectRepository() {
        XCTAssertEqual(SupportLinks.all.count, 3)
        for url in SupportLinks.all {
            XCTAssertEqual(url.scheme, "https", "\(url)")
            XCTAssertEqual(url.host, "github.com", "\(url)")
            XCTAssertTrue(url.path.hasPrefix("/berkinefeavci/PanelLight/"), "\(url)")
        }
    }

    @MainActor func testDimmingOverlayNeverTakesInputOrCoversThePanel() {
        let window = SoftwareDimmer.makeOverlayWindow()
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue, "the panel stays above the overlay")
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.mainMenu.rawValue, "still above the menu bar")
    }
}
