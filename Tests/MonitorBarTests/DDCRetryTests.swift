import XCTest
@testable import MonitorBar

final class DDCRetryTests: XCTestCase {
    private func probe(_ id: UInt32, brightness: UInt16?, issue: DDCIssue? = nil) -> DDCProbe {
        DDCProbe(display: DisplayIdentity(id: id, name: "M\(id)", vendor: 1, product: 1, serial: id),
                 brightness: brightness.map { HardwareLevels(current: $0, maximum: 100) },
                 contrast: nil, input: nil, issue: brightness == nil ? (issue ?? .noAnswer) : nil)
    }

    func testRetryingStopsAtTheFirstAnswerAndPausesBetweenTries() {
        var calls = 0
        var pauses: [TimeInterval] = []
        let result = retrying(DDCRetryPolicy(attempts: 3, delay: 0.25), pause: { pauses.append($0) }) { () -> Int? in
            calls += 1
            return calls == 2 ? 7 : nil
        }
        XCTAssertEqual(result, 7)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(pauses, [0.25])
    }

    func testRetryingGivesUpAfterTheLastAttempt() {
        var calls = 0
        var pauses = 0
        let result = retrying(DDCRetryPolicy(attempts: 3, delay: 0.1), pause: { _ in pauses += 1 }) { () -> Int? in
            calls += 1
            return nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(pauses, 2)
        XCTAssertNil(retrying(DDCRetryPolicy(attempts: 0, delay: 0), pause: { _ in }) { () -> Int? in nil }, "zero attempts still tries once")
    }

    func testProbeRetriesOnlyPatientDisplaysThatDidNotAnswer() {
        let displays = [1, 2, 3].map { DisplayIdentity(id: UInt32($0), name: "M", vendor: 1, product: 1, serial: UInt32($0)) }
        var asked: [Set<UInt32>] = []
        var pauses = 0
        let results = settledProbes(for: displays, patient: [1, 2], policy: DDCRetryPolicy(attempts: 3, delay: 0.5),
                                    pause: { _ in pauses += 1 }) { ids in
            asked.append(ids)
            let round = asked.count
            return displays.filter { ids.contains($0.id) }.map { display in
                switch display.id {
                case 1: return self.probe(1, brightness: 50)                       // answers at once
                case 2: return self.probe(2, brightness: round >= 2 ? 40 : nil)   // answers on the retry
                default: return self.probe(3, brightness: nil)                     // known software display, never retried
                }
            }
        }
        XCTAssertEqual(asked, [[1, 2, 3], [2]])
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(results.map(\.display.id), [1, 2, 3])
        XCTAssertEqual(results.map { $0.brightness?.current }, [50, 40, nil])
    }

    func testProbeFallsBackAfterAllAttemptsAndKeepsTheNewestReason() {
        let display = DisplayIdentity(id: 9, name: "M", vendor: 1, product: 1, serial: 9)
        var rounds = 0
        let results = settledProbes(for: [display], patient: [9], policy: DDCRetryPolicy(attempts: 3, delay: 0),
                                    pause: { _ in }) { _ in
            rounds += 1
            return [self.probe(9, brightness: nil, issue: rounds == 1 ? .noConnection : .noAnswer)]
        }
        XCTAssertEqual(rounds, 3)
        XCTAssertNil(results[0].brightness)
        XCTAssertEqual(results[0].issue, .noAnswer)
    }

    func testWakeWaitsBeforeProbingAgain() {
        let discovery = DisplayDiscovery(wakeSettleDelay: 0.2)
        var forced = 0
        let wake = expectation(description: "forced refresh after the settle delay")
        discovery.onChange = { _, force in
            guard force else { return }
            forced += 1
            wake.fulfill()
        }
        discovery.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        XCTAssertEqual(forced, 0, "no probe right at wake")
        wait(for: [wake], timeout: 2)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(forced, 1, "two wake notifications give one refresh")
        discovery.stop()
    }
}
