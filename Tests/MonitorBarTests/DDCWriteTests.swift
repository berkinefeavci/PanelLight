import XCTest
@testable import MonitorBar

// A monitor control as seen over DDC/CI: it may take a few readings to land, refuse everything (locked),
// or refuse only levels past a limit of its own.
private final class FakeControl {
    var value: UInt16
    var pending: [UInt16] = []      // readings still on the way to `value` after a write
    var locked = false
    var floor: UInt16 = 0
    var landing: (UInt16, UInt16) -> [UInt16] = { _, _ in [] }
    var dropNextWrite = false
    var unreadableAfterReads: Int?
    private(set) var writes: [UInt16] = []
    private(set) var reads = 0

    init(_ value: UInt16) { self.value = value }

    func write(_ raw: UInt16) -> Bool {
        writes.append(raw)
        if dropNextWrite { dropNextWrite = false; return true }
        guard !locked, raw >= floor else { return true }
        pending = landing(value, raw)
        value = raw
        return true
    }

    func read() -> HardwareLevels? {
        reads += 1
        if let limit = unreadableAfterReads, reads > limit { return nil }
        let shown = pending.isEmpty ? value : pending.removeFirst()
        return HardwareLevels(current: shown, maximum: 100)
    }
}

final class DDCWriteTests: XCTestCase {
    private let policy = DDCSettlePolicy(pauses: [0.1, 0.25, 0.4], resendPause: 0.3)

    private func run(_ control: FakeControl, to requested: UInt16) -> (DDCWriteResult, paused: TimeInterval) {
        let before = HardwareLevels(current: control.value, maximum: 100)
        var paused: TimeInterval = 0
        _ = control.write(requested)
        let result = settleWrite(requested: requested, before: before, policy: policy, pause: { paused += $0 },
                                 write: control.write, read: control.read)
        return (result, paused)
    }

    private func level(_ value: UInt16) -> HardwareLevels { HardwareLevels(current: value, maximum: 100) }

    func testValueThatLandsAtOnceNeedsOneReading() {
        let control = FakeControl(70)
        let result = run(control, to: 40)
        XCTAssertEqual(result.0, .applied(level(40)))
        XCTAssertEqual(control.reads, 1)
        XCTAssertEqual(result.paused, 0)
    }

    func testSlowMonitorIsWaitedForInsteadOfReportedAsDifferent() {
        // The old code read once, called the 70 "a different value" and threw the slider back.
        let control = FakeControl(70)
        control.landing = { old, _ in [old, old] }
        XCTAssertEqual(run(control, to: 40).0, .applied(level(40)))
        XCTAssertEqual(control.writes, [40], "no resend once it lands")
    }

    func testFadingMonitorIsFollowedUntilItArrives() {
        let control = FakeControl(70)
        control.landing = { _, _ in [62, 51] }
        XCTAssertEqual(run(control, to: 40).0, .applied(level(40)))
    }

    func testMonitorThatRoundsTheLevelIsAcceptedWhereItLands() {
        let control = FakeControl(70)
        control.landing = { _, _ in [42, 42, 42, 42, 42] }
        XCTAssertEqual(run(control, to: 41).0, .adjusted(level(42)))
        XCTAssertEqual(control.reads, 2, "stops once the new level holds")
    }

    func testLockedControlIsReportedIgnored() {
        // The TCL 27G64: contrast reads 50 and stays 50 whatever is written.
        let control = FakeControl(50)
        control.locked = true
        let result = run(control, to: 45)
        XCTAssertEqual(result.0, .ignored(level(50)))
        XCTAssertEqual(control.writes, [45, 45, 51], "resend, then one step back")
        XCTAssertEqual(control.value, 50)
    }

    func testLimitOfTheMonitorIsNotMistakenForALock() {
        let control = FakeControl(10)
        control.floor = 10
        let result = run(control, to: 4)
        XCTAssertEqual(result.0, .adjusted(level(10)), "it takes a step back, so it is only at its floor")
        XCTAssertEqual(control.writes, [4, 4, 11, 10])
        XCTAssertEqual(control.value, 10, "the test step is put back")
    }

    func testLockedAtTheTopHasNoStepBackAndIsIgnored() {
        let control = FakeControl(100)
        control.locked = true
        XCTAssertEqual(run(control, to: 90).0, .ignored(level(100)))
        XCTAssertEqual(control.writes, [90, 90], "nothing above the maximum to step to")

        let atZero = FakeControl(0)
        atZero.locked = true
        XCTAssertEqual(run(atZero, to: 20).0, .ignored(level(0)))
        XCTAssertEqual(atZero.writes, [20, 20], "nothing below 0 to step to")
    }

    func testLostRequestIsRecoveredByTheResend() {
        let control = FakeControl(50)
        control.dropNextWrite = true
        XCTAssertEqual(run(control, to: 45).0, .applied(level(45)))
        XCTAssertEqual(control.writes, [45, 45])
    }

    func testNoReadingIsUnreadable() {
        let control = FakeControl(50)
        control.unreadableAfterReads = 0
        XCTAssertEqual(run(control, to: 45).0, .unreadable)
    }

    func testReadingLostMidwayKeepsTheLastAnswer() {
        let control = FakeControl(50)
        control.landing = { _, _ in [47] }
        control.unreadableAfterReads = 1
        XCTAssertEqual(run(control, to: 45).0, .adjusted(level(47)))
    }
}
