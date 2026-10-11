import XCTest
import DDCBridge

final class DDCPacketTests: XCTestCase {
    func testGetAndSetPacketsHaveDDCChecksums() {
        var get = [UInt8](repeating: 0, count: 4)
        MBMakeGetPacket(0x10, &get)
        XCTAssertEqual(get, [0x82, 0x01, 0x10, 0xAC])

        var set = [UInt8](repeating: 0, count: 6)
        MBMakeSetPacket(0x10, 52, &set)
        XCTAssertEqual(set, [0x84, 0x03, 0x10, 0x00, 0x34, 0x9C])
    }

    func testReplyParserChecksCodeBoundsAndChecksum() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3A, 0]
        reply[10] = reply.prefix(10).reduce(UInt8(0x50), ^)
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        XCTAssertTrue(MBParseReply(reply, reply.count, 0x10, &current, &maximum))
        XCTAssertEqual(current, 58)
        XCTAssertEqual(maximum, 100)

        XCTAssertFalse(MBParseReply(reply, reply.count, 0x12, &current, &maximum))
        reply[10] ^= 1
        XCTAssertFalse(MBParseReply(reply, reply.count, 0x10, &current, &maximum))
        reply[10] ^= 1
        reply[7] = 0
        reply[10] = reply.prefix(10).reduce(UInt8(0x50), ^)
        XCTAssertFalse(MBParseReply(reply, reply.count, 0x10, &current, &maximum))
    }

    private func reply(code: UInt8 = 0x10, maximum: UInt16 = 100, current: UInt16 = 58) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF), 0]
        bytes[10] = bytes.prefix(10).reduce(UInt8(0x50), ^)
        return bytes
    }

    func testReplyParserRejectsShortOrMalformedReplies() {
        var current: UInt16 = 0xBEEF
        var maximum: UInt16 = 0xBEEF
        let good = reply()
        XCTAssertTrue(MBParseReply(good, good.count, 0x10, &current, &maximum))

        for length in 0..<11 {   // never reads past what the monitor returned
            XCTAssertFalse(MBParseReply(good, length, 0x10, &current, &maximum), "length \(length)")
        }
        XCTAssertFalse(MBParseReply(nil, 11, 0x10, &current, &maximum))

        for (index, wrong) in [(0, UInt8(0x6F)), (1, UInt8(0x87)), (2, UInt8(0x03)), (3, UInt8(0x01))] {
            var broken = good
            broken[index] = wrong
            broken[10] = broken.prefix(10).reduce(UInt8(0x50), ^)   // valid checksum, wrong header field
            XCTAssertFalse(MBParseReply(broken, broken.count, 0x10, &current, &maximum), "header byte \(index)")
        }
        let tooHigh = reply(maximum: 100, current: 101)
        XCTAssertFalse(MBParseReply(tooHigh, tooHigh.count, 0x10, &current, &maximum))
        let noMaximum = reply(maximum: 0, current: 0)
        XCTAssertFalse(MBParseReply(noMaximum, noMaximum.count, 0x10, &current, &maximum))
        XCTAssertEqual(current, 58, "a rejected reply leaves the outputs alone")
        XCTAssertEqual(maximum, 100)
    }

    func testReplyParserAcceptsNilOutputsAndTrailingBytes() {
        var padded = reply()
        padded += [0, 0, 0]
        XCTAssertTrue(MBParseReply(padded, padded.count, 0x10, nil, nil))
    }
}
