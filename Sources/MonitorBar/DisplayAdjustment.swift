import CoreGraphics
import Foundation

func adjustedContrastTable(_ values: [CGGammaValue], percent: Double) -> [CGGammaValue] {
    let factor = Float(0.5 + min(100, max(0, percent)) / 100)
    return values.map { min(1, max(0, ($0 - 0.5) * factor + 0.5)) }
}

// Contrast through the display's gamma table: the built-in display, and monitors that keep DDC/CI contrast fixed.
final class GammaContrastController {
    // The key name predates external displays; kept so a crash in an older build is still recovered.
    private static let modifiedKey = "builtInGammaModified"

    // A crash skips restore, leaving the contrast curve on screen until the next launch.
    static func recoverAfterCrash() {
        guard UserDefaults.standard.bool(forKey: modifiedKey) else { return }
        CGDisplayRestoreColorSyncSettings()
        UserDefaults.standard.set(false, forKey: modifiedKey)
    }

    private typealias Table = ([CGGammaValue], [CGGammaValue], [CGGammaValue])
    private var originals: [CGDirectDisplayID: Table] = [:]

    var adjustedDisplays: Set<CGDirectDisplayID> { Set(originals.keys) }

    func apply(_ percent: Double, to display: CGDirectDisplayID) -> Bool {
        if originals[display] == nil {
            let capacity = CGDisplayGammaTableCapacity(display)
            guard capacity > 0 else { return false }
            var red = [CGGammaValue](repeating: 0, count: Int(capacity))
            var green = red
            var blue = red
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success,
                  count > 0 else { return false }
            originals[display] = (Array(red.prefix(Int(count))), Array(green.prefix(Int(count))),
                                  Array(blue.prefix(Int(count))))
        }
        guard let original = originals[display] else { return false }
        let red = adjustedContrastTable(original.0, percent: percent)
        let green = adjustedContrastTable(original.1, percent: percent)
        let blue = adjustedContrastTable(original.2, percent: percent)
        guard CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue) == .success else { return false }
        UserDefaults.standard.set(true, forKey: Self.modifiedKey)
        return true
    }

    func restore(_ display: CGDirectDisplayID) {
        if let original = originals.removeValue(forKey: display) {
            _ = CGSetDisplayTransferByTable(display, UInt32(original.0.count), original.0, original.1, original.2)
        }
        if originals.isEmpty { UserDefaults.standard.set(false, forKey: Self.modifiedKey) }
    }

    func restoreAll() {
        for display in adjustedDisplays { restore(display) }
        UserDefaults.standard.set(false, forKey: Self.modifiedKey)
    }
}
