import Foundation

struct DisplayIdentity: Equatable, Sendable {
    let id: UInt32
    let name: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    var isVirtual = false
    // The framebuffer driving the display ("dispext0", …); see framebufferPort(fromDisplayLocation:).
    var port: String? = nil
}

struct DDCIdentity: Equatable, Sendable {
    let index: Int32
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    var port: String? = nil
}

// "disp0", "dispext0", "dispext12": the framebuffer name the display and its DDC service both carry.
private func framebufferName(_ component: Substring) -> String? {
    let name = component.prefix { $0 != "@" && $0 != ":" }
    guard name.hasPrefix("disp") else { return nil }
    let number = name.dropFirst(4).drop { $0.isLetter }
    return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber) ? String(name) : nil
}

// CoreDisplay's IODisplayLocation: ".../AppleSoCIO/dispext0@B0000000/IOMobileFramebufferShim" -> "dispext0".
func framebufferPort(fromDisplayLocation location: String) -> String? {
    location.split(separator: "/").reversed().lazy.compactMap(framebufferName).first
}

// A DDC service path: ".../dispext0:dcpav-service-epic:0/DCPAVServiceProxy" -> "dispext0".
func framebufferPort(fromServicePath path: String) -> String? {
    path.split(separator: "/").reversed().lazy.filter { $0.contains("dcpav-service") }.compactMap(framebufferName).first
}

private func knownAndDifferent(_ a: UInt32, _ b: UInt32) -> Bool { a != 0 && b != 0 && a != b }

func matchDisplays(_ displays: [DisplayIdentity], to services: [DDCIdentity]) -> [UInt32: Int32] {
    var result: [UInt32: Int32] = [:]
    var used = Set<Int32>()

    // The framebuffer port is the same wire seen from both sides, so it tells identical monitors apart even when
    // their EDIDs carry no serial (or a placeholder such as 0xFFFFFFFF). An EDID naming another model wins over it.
    for display in displays {
        guard let port = display.port, displays.filter({ $0.port == port }).count == 1 else { continue }
        let matches = services.filter { $0.port == port }
        guard matches.count == 1, !knownAndDifferent(matches[0].vendor, display.vendor),
              !knownAndDifferent(matches[0].product, display.product) else { continue }
        result[display.id] = matches[0].index
        used.insert(matches[0].index)
    }

    for display in displays where display.serial != 0 && result[display.id] == nil {
        let sameDisplayCount = displays.filter {
            $0.vendor == display.vendor && $0.product == display.product && $0.serial == display.serial
        }.count
        let matches = services.filter {
            !used.contains($0.index) &&
            $0.vendor == display.vendor && $0.product == display.product && $0.serial == display.serial
        }
        if sameDisplayCount == 1 && matches.count == 1 {
            result[display.id] = matches[0].index
            used.insert(matches[0].index)
        }
    }

    for display in displays where result[display.id] == nil {
        let matchingDisplays = displays.filter {
            result[$0.id] == nil && $0.vendor == display.vendor && $0.product == display.product
        }
        let matchingServices = services.filter {
            !used.contains($0.index) && $0.vendor == display.vendor && $0.product == display.product &&
            ($0.serial == 0 || display.serial == 0 || $0.serial == display.serial)
        }
        if matchingDisplays.count == 1 && matchingServices.count == 1 && display.vendor != 0 && display.product != 0 {
            result[display.id] = matchingServices[0].index
            used.insert(matchingServices[0].index)
        }
    }

    if result.isEmpty && displays.count == 1 && services.count == 1 &&
        services[0].vendor == 0 && services[0].product == 0 {
        result[displays[0].id] = services[0].index
    }
    return result
}

func rawLevel(percent value: Double, maximum: UInt16) -> UInt16? {
    guard maximum > 0 && value.isFinite else { return nil }
    return UInt16((min(100, max(0, value)) / 100 * Double(maximum)).rounded())
}

func percent(current: UInt16, maximum: UInt16) -> Double? {
    guard maximum > 0 && current <= maximum else { return nil }
    return Double(current) / Double(maximum) * 100
}
