import XCTest
@testable import MonitorBar

final class StripButtonProbeTests: XCTestCase {
    /// A 200 × 32 pt strip at 2x: grey, with a red disc and a green disc (14 pt) like the real buttons.
    private func strip(red: CGPoint?, green: CGPoint?, diameter: CGFloat = 14, scale: CGFloat = 2) -> (bytes: [UInt8], w: Int, h: Int) {
        let w = Int(200 * scale), h = Int(32 * scale)
        var p = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                var (r, g, b): (UInt8, UInt8, UInt8) = (58, 58, 60)
                let pt = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if let c = red, hypot(pt.x - c.x, pt.y - c.y) < diameter / 2 { (r, g, b) = (255, 95, 87) }
                if let c = green, hypot(pt.x - c.x, pt.y - c.y) < diameter / 2 { (r, g, b) = (40, 200, 64) }
                p[o] = b; p[o + 1] = g; p[o + 2] = r; p[o + 3] = 255
            }
        }
        return (p, w, h)
    }

    func testFindsButtonCentres() throws {
        let s = strip(red: CGPoint(x: 26.75, y: 16), green: CGPoint(x: 72.75, y: 16))
        let l = try XCTUnwrap(StripButtonProbe.detect(bgra: s.bytes, width: s.w, height: s.h, bytesPerRow: s.w * 4, scale: 2))
        XCTAssertEqual(l.centers[0], 26.75, accuracy: 0.5)
        XCTAssertEqual(l.centers[1], 49.75, accuracy: 0.5)
        XCTAssertEqual(l.centers[2], 72.75, accuracy: 0.5)
        XCTAssertEqual(l.centerY, 16, accuracy: 0.5)
        XCTAssertEqual(l.diameter, 14, accuracy: 1)
    }

    func testFindsShiftedButtons() throws {
        let s = strip(red: CGPoint(x: 15.4, y: 15), green: CGPoint(x: 61.4, y: 15))
        let l = try XCTUnwrap(StripButtonProbe.detect(bgra: s.bytes, width: s.w, height: s.h, bytesPerRow: s.w * 4, scale: 2))
        XCTAssertEqual(l.centers[0], 15.4, accuracy: 0.5)
        XCTAssertEqual(l.centers[2], 61.4, accuracy: 0.5)
        XCTAssertEqual(l.centerY, 15, accuracy: 0.5)
    }

    func testIgnoresButtonsCutOffWhileSliding() {
        // Mid-animation the strip is still partly under the menu bar: only the lower half of each disc shows.
        let s = strip(red: CGPoint(x: 16, y: 2), green: CGPoint(x: 62, y: 2))
        XCTAssertNil(StripButtonProbe.detect(bgra: s.bytes, width: s.w, height: s.h, bytesPerRow: s.w * 4, scale: 2))
    }

    func testNoButtonsWhenGrey() {
        // An inactive window draws all three buttons grey: keep the last known layout instead of guessing.
        let s = strip(red: nil, green: nil)
        XCTAssertNil(StripButtonProbe.detect(bgra: s.bytes, width: s.w, height: s.h, bytesPerRow: s.w * 4, scale: 2))
    }

    func testStoredRoundTrip() throws {
        let l = StripButtonLayout.standard
        XCTAssertEqual(try XCTUnwrap(StripButtonLayout(stored: l.stored)), l)
        XCTAssertNil(StripButtonLayout(stored: [1, 2]))
        XCTAssertNil(StripButtonLayout(stored: [50, 20, 16, 14]))
    }
}
