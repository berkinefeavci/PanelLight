import DDCBridge
import Foundation

struct HardwareLevels: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16
    var percent: Double { Double(current) / Double(maximum) * 100 }
}

enum DDCIssue: Equatable, Sendable {
    case noConnection   // no DDC/CI service matches this display
    case noAnswer       // a service matches, but the monitor did not answer the brightness request

    var summary: String {
        switch self {
        case .noConnection: "No DDC/CI connection found"
        case .noAnswer: "The monitor did not answer DDC/CI brightness"
        }
    }
}

struct DDCProbe: Sendable {
    let display: DisplayIdentity
    let brightness: HardwareLevels?
    let contrast: HardwareLevels?
    let input: UInt16?
    let issue: DDCIssue?
}

// A monitor that was just woken, switched or replugged often misses the first request. A failure only counts
// after a few attempts with a pause in between; this is what keeps one missed answer from turning a working
// monitor into a "Software" row.
struct DDCRetryPolicy: Sendable {
    var attempts: Int
    var delay: TimeInterval

    static let write = DDCRetryPolicy(attempts: 3, delay: 0.3)
    static let probe = DDCRetryPolicy(attempts: 3, delay: 0.6)
}

typealias DDCPause = (TimeInterval) -> Void

func retrying<T>(_ policy: DDCRetryPolicy, pause: DDCPause = { Thread.sleep(forTimeInterval: $0) },
                 _ attempt: () -> T?) -> T? {
    for number in 0..<max(1, policy.attempts) {
        if number > 0 { pause(policy.delay) }
        if let value = attempt() { return value }
    }
    return nil
}

// Probes every display once, then probes again, with a pause, only the "patient" displays that gave no
// brightness. Displays already known to lack DDC/CI are not patient, so they never slow a refresh down.
func settledProbes(for displays: [DisplayIdentity], patient: Set<UInt32>, policy: DDCRetryPolicy,
                   pause: DDCPause = { Thread.sleep(forTimeInterval: $0) }, probeOnce: (Set<UInt32>) -> [DDCProbe]) -> [DDCProbe] {
    var results = probeOnce(Set(displays.map(\.id)))
    for _ in 1..<max(1, policy.attempts) {
        let missing = Set(results.filter { $0.brightness == nil && patient.contains($0.display.id) }.map(\.display.id))
        if missing.isEmpty { break }
        pause(policy.delay)
        let again = probeOnce(missing)
        results = results.map { old in again.first { $0.display.id == old.display.id } ?? old }
    }
    return results
}

final class DDCClient: @unchecked Sendable {
    static let shared = DDCClient()
    private let queue = DispatchQueue(label: "com.berkinavci.MonitorBar.ddc", qos: .userInitiated)

    func probe(displays: [DisplayIdentity], patient: Set<UInt32> = [],
               completion: @escaping @Sendable ([DDCProbe]) -> Void) {
        queue.async {
            let result = settledProbes(for: displays, patient: patient, policy: .probe) { ids in
                Self.probeOnce(displays, reading: ids)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func write(display: DisplayIdentity, vcp: UInt8, raw: UInt16,
               completion: @escaping @Sendable (HardwareLevels?) -> Void) {
        queue.async {
            let result = retrying(.write) { Self.writeOnce(display: display, vcp: vcp, raw: raw) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Matching always sees every display, so identical twins stay ambiguous; only `ids` are read.
    private static func probeOnce(_ displays: [DisplayIdentity], reading ids: Set<UInt32>) -> [DDCProbe] {
        MBRescan()
        let matched = matchDisplays(displays, to: services())
        return displays.filter { ids.contains($0.id) }.map { display in
            guard let index = matched[display.id] else {
                return DDCProbe(display: display, brightness: nil, contrast: nil, input: nil, issue: .noConnection)
            }
            let brightness = read(0x10, index: index)
            let contrast = read(0x12, index: index)
            let input = read(0x60, index: index)?.current
            return DDCProbe(display: display, brightness: brightness, contrast: contrast, input: input,
                            issue: brightness == nil ? .noAnswer : nil)
        }
    }

    private static func writeOnce(display: DisplayIdentity, vcp: UInt8, raw: UInt16) -> HardwareLevels? {
        MBRescan()
        guard let index = matchDisplays([display], to: services())[display.id],
              let before = read(vcp, index: index), raw <= before.maximum,
              MBWriteVCP(index, vcp, raw) else { return nil }
        return read(vcp, index: index)
    }

    private static func services() -> [DDCIdentity] {
        let count = MBServiceCount()
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            var vendor: UInt32 = 0
            var product: UInt32 = 0
            var serial: UInt32 = 0
            _ = MBServiceIdentity(index, &vendor, &product, &serial)
            return DDCIdentity(index: index, vendor: vendor, product: product, serial: serial)
        }
    }

    private static func read(_ code: UInt8, index: Int32) -> HardwareLevels? {
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        guard MBReadVCP(index, code, &current, &maximum),
              percent(current: current, maximum: maximum) != nil else { return nil }
        return HardwareLevels(current: current, maximum: maximum)
    }
}
