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

// What a monitor did with a written value, judged from what it reports afterwards.
enum DDCWriteResult: Equatable, Sendable {
    case applied(HardwareLevels)   // it reports the requested level
    case adjusted(HardwareLevels)  // it moved, but settled on a level of its own (rounded or clamped)
    case ignored(HardwareLevels)   // it kept the level it had: the control is locked (HDR, picture mode, …)
    case unreadable                // no reading before or after the write
}

// Many monitors take a few hundred milliseconds to land on a new level, and some fade to it. One reading right
// after the write called those "a different value" and threw the slider back, so the reading is repeated while
// the value is still on its way.
struct DDCSettlePolicy: Sendable {
    var pauses: [TimeInterval]
    var resendPause: TimeInterval

    static let write = DDCSettlePolicy(pauses: [0.1, 0.25, 0.4], resendPause: 0.3)
}

// `write` sends a raw level, `read` reads the control. The first write has already been sent.
func settleWrite(requested: UInt16, before: HardwareLevels, policy: DDCSettlePolicy = .write,
                 pause: DDCPause = { Thread.sleep(forTimeInterval: $0) },
                 write: (UInt16) -> Bool, read: () -> HardwareLevels?) -> DDCWriteResult {
    guard var last = read() else { return .unreadable }
    for wait in policy.pauses where last.current != requested {
        pause(wait)
        guard let next = read() else { break }
        // Off the old level and holding still: the monitor has landed where it wants to be.
        let landed = next.current == last.current && next.current != before.current
        last = next
        if landed { break }
    }
    if last.current == requested { return .applied(last) }
    if last.current != before.current { return .adjusted(last) }

    // Still on the old level. One more write tells a request lost on the wire from a refusal.
    guard write(requested) else { return .ignored(last) }
    pause(policy.resendPause)
    let resent = read() ?? last
    if resent.current == requested { return .applied(resent) }
    if resent.current != before.current { return .adjusted(resent) }

    // Refused twice. A monitor sitting at a limit of its own (a brightness floor in an eco mode, say) refuses a
    // step past it but takes a step back; a locked control takes neither. The step is put back right away.
    let back: UInt16? = requested < before.current
        ? (before.current < before.maximum ? before.current + 1 : nil)
        : (before.current > 0 ? before.current - 1 : nil)
    guard let back, write(back) else { return .ignored(resent) }
    pause(policy.resendPause)
    guard let stepped = read(), stepped.current != before.current else { return .ignored(resent) }
    _ = write(before.current)
    pause(policy.resendPause)
    return .adjusted(read() ?? before)
}

func cString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
               completion: @escaping @Sendable (DDCWriteResult) -> Void) {
        queue.async {
            let result = retrying(.write) { Self.writeOnce(display: display, vcp: vcp, raw: raw) } ?? .unreadable
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

    // nil only when the monitor could not be read or written at all, so `retrying` tries the whole thing again.
    private static func writeOnce(display: DisplayIdentity, vcp: UInt8, raw: UInt16) -> DDCWriteResult? {
        MBRescan()
        guard let index = matchDisplays([display], to: services())[display.id],
              let before = read(vcp, index: index), raw <= before.maximum else { return nil }
        if before.current == raw { return .applied(before) }
        guard MBWriteVCP(index, vcp, raw) else { return nil }
        let result = settleWrite(requested: raw, before: before,
                                 write: { MBWriteVCP(index, vcp, $0) }, read: { read(vcp, index: index) })
        return result == .unreadable ? nil : result
    }

    private static func services() -> [DDCIdentity] {
        let count = MBServiceCount()
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            var vendor: UInt32 = 0
            var product: UInt32 = 0
            var serial: UInt32 = 0
            _ = MBServiceIdentity(index, &vendor, &product, &serial)
            var path = [CChar](repeating: 0, count: 512)
            let port = MBServicePath(index, &path, path.count) ? framebufferPort(fromServicePath: cString(path)) : nil
            return DDCIdentity(index: index, vendor: vendor, product: product, serial: serial, port: port)
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
