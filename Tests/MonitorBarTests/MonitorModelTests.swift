import XCTest
@testable import MonitorBar

final class MonitorModelTests: XCTestCase {
    func testOnlyLatestPendingWriteRuns() async throws {
        await MainActor.run {
            TestRetainer.writes = []
            let scheduler = WriteScheduler()
            scheduler.schedule(after: 0.04) { TestRetainer.writes.append(25) }
            scheduler.schedule(after: 0.04) { TestRetainer.writes.append(60) }
            TestRetainer.scheduler = scheduler
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let values = await MainActor.run { TestRetainer.writes }
        XCTAssertEqual(values, [60])
        await MainActor.run { TestRetainer.scheduler = nil }
    }

    func testDisconnectCancelsPendingWrite() async throws {
        await MainActor.run {
            TestRetainer.writes = []
            let scheduler = WriteScheduler()
            scheduler.schedule(after: 0.04) { TestRetainer.writes.append(52) }
            scheduler.cancel()
            TestRetainer.scheduler = scheduler
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let count = await MainActor.run { TestRetainer.writes.count }
        XCTAssertEqual(count, 0)
        await MainActor.run { TestRetainer.scheduler = nil }
    }

    func testLiveWritesStartImmediatelyAndCoalesceWhileBusy() async {
        await MainActor.run {
            let queue = LatestWriteQueue()
            TestRetainer.writes = []
            TestRetainer.finishWrite = nil
            queue.submit { finish in
                TestRetainer.writes.append(10)
                TestRetainer.finishWrite = finish
            }
            XCTAssertEqual(TestRetainer.writes, [10])
            queue.submit { finish in TestRetainer.writes.append(20); finish() }
            queue.submit { finish in TestRetainer.writes.append(30); finish() }
            XCTAssertEqual(TestRetainer.writes, [10])
            TestRetainer.finishWrite?()
            XCTAssertEqual(TestRetainer.writes, [10, 30])
            TestRetainer.finishWrite = nil
        }
    }

    @MainActor func testUnchangedPollReadingsDoNotRedrawPanel() {
        let model = MonitorModel()
        var changes = 0
        let watcher = model.objectWillChange.sink { changes += 1 }
        model.receivePolledKeyboardBrightness(40)
        model.receivePolledNightShift(false)
        model.receivePolledBuiltInBrightness(70)
        XCTAssertEqual(changes, 3)
        for _ in 0..<5 {
            model.receivePolledKeyboardBrightness(40)
            model.receivePolledNightShift(false)
            model.receivePolledBuiltInBrightness(70)
        }
        XCTAssertEqual(changes, 3, "a reading equal to the shown value must not publish")
        model.receivePolledKeyboardBrightness(55)
        model.receivePolledBuiltInBrightness(71)
        XCTAssertEqual(changes, 5)
        XCTAssertEqual(model.keyboardBrightnessValue, 55)
        XCTAssertEqual(model.builtInBrightnessValue, 71)
        watcher.cancel()
    }

    @MainActor func testMessageGoesAwayWhenItsConditionRecovers() {
        let model = MonitorModel()
        model.report("Keyboard backlight is unavailable", source: .keyboardUnavailable)
        model.receivePolledKeyboardBrightness(nil)
        model.receivePolledBuiltInBrightness(50)
        XCTAssertEqual(model.errorMessage, "Keyboard backlight is unavailable", "still missing, and an unrelated recovery")
        model.receivePolledKeyboardBrightness(40)
        XCTAssertNil(model.errorMessage)

        model.report("Built-in display brightness is unavailable", source: .builtInUnavailable)
        model.receivePolledKeyboardBrightness(41)
        XCTAssertNotNil(model.errorMessage)
        model.receivePolledBuiltInBrightness(51)
        XCTAssertNil(model.errorMessage)

        model.report("Night Shift change was not confirmed")
        model.receivePolledKeyboardBrightness(42)
        model.receivePolledBuiltInBrightness(52)
        XCTAssertNotNil(model.errorMessage, "a failed change stays until the next action or refresh")
        model.clearError()
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testClearingNothingDoesNotRedrawPanel() {
        let model = MonitorModel()
        var changes = 0
        let watcher = model.objectWillChange.sink { changes += 1 }
        model.clearError()
        model.clearError(from: .display)
        XCTAssertEqual(changes, 0)
        model.report("x", source: .display)
        model.report("x", source: .display)
        XCTAssertEqual(changes, 1)
        model.clearError(from: .keyboardUnavailable)
        XCTAssertEqual(model.errorMessage, "x")
        watcher.cancel()
    }

    func testPollingRunsOnlyWhereSomethingNeedsIt() {
        XCTAssertFalse(pollingNeeded(panelVisible: false, linkOn: false, hasBuiltIn: true, hasLinkedDisplay: true),
                       "closed panel, Link off: no timer at all")
        XCTAssertTrue(pollingNeeded(panelVisible: true, linkOn: false, hasBuiltIn: false, hasLinkedDisplay: false))
        XCTAssertTrue(pollingNeeded(panelVisible: false, linkOn: true, hasBuiltIn: true, hasLinkedDisplay: true),
                      "Link follows the brightness keys while the panel is closed")
        XCTAssertFalse(pollingNeeded(panelVisible: false, linkOn: true, hasBuiltIn: false, hasLinkedDisplay: true))
        XCTAssertFalse(pollingNeeded(panelVisible: false, linkOn: true, hasBuiltIn: true, hasLinkedDisplay: false))
    }

    @MainActor func testPollTimerRunsOnlyWhilePanelIsOpen() {
        let model = MonitorModel()
        XCTAssertFalse(model.isPolling)
        model.setPanelVisible(true)
        XCTAssertTrue(model.isPolling)
        model.setPanelVisible(true)
        XCTAssertTrue(model.isPolling)
        model.setPanelVisible(false)
        XCTAssertFalse(model.isPolling, "closed panel with Link off needs no timer")
    }

    func testWriteRequiresMatchingReadback() {
        XCTAssertEqual(writeOutcome(requested: 52, readback: HardwareLevels(current: 52, maximum: 100)), .verified)
        XCTAssertEqual(writeOutcome(requested: 52, readback: HardwareLevels(current: 58, maximum: 100)), .mismatch)
        XCTAssertEqual(writeOutcome(requested: 52, readback: nil), .unreadable)
    }
}

@MainActor private enum TestRetainer {
    static var scheduler: WriteScheduler?
    static var writes: [Int] = []
    static var finishWrite: (@MainActor () -> Void)?
}
