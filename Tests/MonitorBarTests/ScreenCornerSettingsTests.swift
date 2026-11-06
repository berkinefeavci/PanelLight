import Foundation
import XCTest
@testable import MonitorBar

final class ScreenCornerSettingsTests: XCTestCase {
    // ScreenCorners reloads on UserDefaults.didChangeNotification; if load() posted it, Settings crashed by recursion.
    func testLoadDoesNotPostDefaultsChange() {
        let suite = "ScreenCornerSettingsTests"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                           object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertEqual(ScreenCornerSettings.load(d), ScreenCornerSettings())
        XCTAssertEqual(posts, 0)
    }

    func testLoadReadsStoredValues() {
        let suite = "ScreenCornerSettingsTests2"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: ScreenCornerKeys.enabled)
        d.set(99.0, forKey: ScreenCornerKeys.radius)
        d.set(false, forKey: ScreenCornerKeys.top)
        let s = ScreenCornerSettings.load(d)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.radius, 60)
        XCTAssertFalse(s.top)
        XCTAssertTrue(s.bottom)
    }
    func testNonFiniteRadiusFallsBackToDefault() {
        let suite = "ScreenCornerSettingsTests-invalid-radius"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for radius in [Double.nan, Double.infinity, -Double.infinity] {
            defaults.set(radius, forKey: ScreenCornerKeys.radius)
            XCTAssertEqual(ScreenCornerSettings.load(defaults).radius, ScreenCornerKeys.defaultRadius)
        }
    }
}
