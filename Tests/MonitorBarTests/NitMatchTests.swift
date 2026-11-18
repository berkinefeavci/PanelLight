import XCTest
@testable import MonitorBar

final class NitMatchTests: XCTestCase {
    let mac = NitProfile(minNits: 2, maxNits: 1000, gamma: 2.2)
    let monitor = NitProfile(minNits: 40, maxNits: 300, gamma: 1)

    func testBottomIsBlackOnEveryScreen() {
        let nits = NitMatch.nits(atLevel: 0, top: 1000)
        XCTAssertEqual(NitMatch.setting(forNits: nits, profile: mac).light, 0)
        XCTAssertEqual(NitMatch.setting(forNits: nits, profile: monitor).light, 0)
        XCTAssertEqual(NitMatch.setting(forNits: nits, profile: monitor).hardware, 0)
    }

    func testBelowMonitorMinimumUsesOverlay() {
        let s = NitMatch.setting(forNits: 20, profile: monitor)
        XCTAssertEqual(s.hardware, 0)
        XCTAssertEqual(s.light, 0.5, accuracy: 1e-9)
    }

    func testAboveMonitorMaximumOnlyMacMoves() {
        let snap = NitMatch.level(forNits: 300, top: 1000)
        let above = NitMatch.nits(atLevel: snap + 10, top: 1000)
        XCTAssertEqual(NitMatch.setting(forNits: above, profile: monitor).hardware, 100)
        XCTAssertLessThan(NitMatch.setting(forNits: above, profile: mac).hardware, 100)
        XCTAssertEqual(NitMatch.setting(forNits: 1000, profile: mac).hardware, 100)
    }

    func testSameNitsOnBothScreens() {
        let nits = 150.0
        let m = NitMatch.setting(forNits: nits, profile: mac)
        let e = NitMatch.setting(forNits: nits, profile: monitor)
        XCTAssertEqual(NitMatch.nits(atHardware: m.hardware, profile: mac), nits, accuracy: 0.01)
        XCTAssertEqual(NitMatch.nits(atHardware: e.hardware, profile: monitor), nits, accuracy: 0.01)
    }

    func testLevelRoundTrip() {
        for level in stride(from: 0.0, through: 100, by: 12.5) {
            XCTAssertEqual(NitMatch.level(forNits: NitMatch.nits(atLevel: level, top: 1000), top: 1000), level, accuracy: 1e-9)
        }
    }
}
