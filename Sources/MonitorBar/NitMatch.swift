import Foundation
import SwiftUI

// Matched brightness for Link: one bar in nits for every screen instead of the same percent on each.
// The bar runs from black (0) to the brightest screen's maximum on a perceptual curve. Each screen turns the
// target into its own hardware level; below its lowest light a black overlay dims it further, so the bottom of
// the bar is black everywhere. Above a monitor's maximum the monitor stays at full and only brighter screens move.
// The nit figures are estimates the user can tune in Settings; nothing here is measured.
struct NitProfile: Equatable, Sendable {
    var minNits: Double   // light at hardware level 0
    var maxNits: Double   // light at hardware level 100
    var gamma: Double     // hardware level -> light curve (Mac backlight ~2.2, monitors ~1)

    static let builtInDefault = NitProfile(minNits: 2, maxNits: 1000, gamma: 2.2)
    static let externalDefault = NitProfile(minNits: 40, maxNits: 300, gamma: 1)
}

enum NitMatch {
    /// Bar position -> light: perceptual, so equal steps on the bar look like equal steps on screen.
    static let barCurve = 2.2

    static func nits(atLevel level: Double, top: Double) -> Double {
        top * pow(clamp(level / 100), barCurve)
    }

    static func level(forNits nits: Double, top: Double) -> Double {
        guard top > 0 else { return 0 }
        return 100 * pow(clamp(nits / top), 1 / barCurve)
    }

    /// Hardware level (0–100) and how much light the overlay lets through (1 = no overlay, 0 = black).
    static func setting(forNits nits: Double, profile p: NitProfile) -> (hardware: Double, light: Double) {
        if nits >= p.maxNits { return (100, 1) }
        if nits <= p.minNits { return (0, p.minNits > 0 ? clamp(nits / p.minNits) : 1) }
        let x = (nits - p.minNits) / max(0.001, p.maxNits - p.minNits)
        return (100 * pow(clamp(x), 1 / p.gamma), 1)
    }

    static func nits(atHardware level: Double, profile p: NitProfile) -> Double {
        p.minNits + (p.maxNits - p.minNits) * pow(clamp(level / 100), p.gamma)
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: Stored profiles

enum NitProfiles {
    static func key(for display: DisplayIdentity, builtIn: Bool) -> String {
        builtIn ? "nits.builtin" : "nits.\(display.vendor)-\(display.product)"
    }

    static func load(_ display: DisplayIdentity, builtIn: Bool, _ d: UserDefaults = .standard) -> NitProfile {
        var p = builtIn ? NitProfile.builtInDefault : NitProfile.externalDefault
        if let saved = d.array(forKey: key(for: display, builtIn: builtIn)) as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite }), saved[0] >= 0, saved[1] > saved[0] {
            p.minNits = saved[0]
            p.maxNits = saved[1]
        }
        return p
    }

    static func save(_ p: NitProfile, for display: DisplayIdentity, builtIn: Bool, _ d: UserDefaults = .standard) {
        d.set([p.minNits, p.maxNits], forKey: key(for: display, builtIn: builtIn))
    }
}

// MARK: Settings

/// Lowest and highest light of each screen, used by Link. Tune by eye until both screens match.
struct NitSettingsView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link matches screens by these values. Raise a screen's lowest value if it stays brighter than the others near the bottom; lower its highest value if it looks dimmer at the top.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.nitDisplays, id: \.display.id) { item in
                NitRow(model: model, display: item.display, builtIn: item.builtIn)
            }
        }
    }
}

private struct NitRow: View {
    @ObservedObject var model: MonitorModel
    let display: DisplayIdentity
    let builtIn: Bool

    var body: some View {
        let p = model.nitProfile(display, builtIn: builtIn)
        VStack(alignment: .leading, spacing: 2) {
            Text(builtIn ? display.name : displayTitle(display))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                field("Lowest", value: p.minNits) { model.setNitProfile(NitProfile(minNits: $0, maxNits: p.maxNits, gamma: p.gamma), for: display, builtIn: builtIn) }
                field("Highest", value: p.maxNits) { model.setNitProfile(NitProfile(minNits: p.minNits, maxNits: $0, gamma: p.gamma), for: display, builtIn: builtIn) }
            }
        }
    }

    private func field(_ title: LocalizedStringKey, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 52)
            Text("nits").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
