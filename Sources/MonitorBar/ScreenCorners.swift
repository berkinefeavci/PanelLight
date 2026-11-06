import AppKit
import SwiftUI

// Rounded screen corners: a click-through black mask in the chosen corners of each screen, so flat-cornered
// displays (MacBook Air, older MacBook Pro bottoms, external monitors) get rounded corners like the hardware.
// It redraws only when one of its settings changes; there is no timer.
enum ScreenCornerKeys {
    static let enabled = "cornersEnabled"
    static let radius = "cornersRadius"
    static let smooth = "cornersSmooth"
    static let external = "cornersExternal"
    static let top = "cornersTop"
    static let bottom = "cornersBottom"
    static let defaultRadius = 16.0
}

struct ScreenCornerSettings: Equatable {
    var enabled = false, radius = ScreenCornerKeys.defaultRadius, smooth = false, external = true, top = true, bottom = true

    static func load(_ d: UserDefaults = .standard) -> ScreenCornerSettings {
        d.register(defaults: [ScreenCornerKeys.enabled: false, ScreenCornerKeys.radius: ScreenCornerKeys.defaultRadius,
                              ScreenCornerKeys.smooth: false, ScreenCornerKeys.external: true,
                              ScreenCornerKeys.top: true, ScreenCornerKeys.bottom: true])
        return ScreenCornerSettings(enabled: d.bool(forKey: ScreenCornerKeys.enabled),
                                    radius: min(60, max(0, d.double(forKey: ScreenCornerKeys.radius))),
                                    smooth: d.bool(forKey: ScreenCornerKeys.smooth),
                                    external: d.bool(forKey: ScreenCornerKeys.external),
                                    top: d.bool(forKey: ScreenCornerKeys.top),
                                    bottom: d.bool(forKey: ScreenCornerKeys.bottom))
    }

    /// Full rect plus the rounded inner rect; filled even-odd, only the corner pieces stay black. Top-left origin.
    func maskPath(in rect: CGRect, scale: CGFloat = 1) -> CGPath {
        let r = min(CGFloat(radius) * scale, rect.width / 2, rect.height / 2)
        let t = top ? r : 0, b = bottom ? r : 0
        let path = CGMutablePath()
        path.addRect(rect)
        if smooth, #available(macOS 14, *) {
            let radii = RectangleCornerRadii(topLeading: t, bottomLeading: b, bottomTrailing: b, topTrailing: t)
            path.addPath(UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect).cgPath)
        } else {
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
            inner.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: t)
            inner.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: b)
            inner.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: b)
            inner.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: t)
            inner.closeSubpath()
            path.addPath(inner)
        }
        return path
    }
}

private final class CornerMaskView: NSView {
    var settings = ScreenCornerSettings() { didSet { if settings != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.addPath(settings.maskPath(in: bounds))
        c.setFillColor(NSColor.black.cgColor)
        c.fillPath(using: .evenOdd)
    }
}

@MainActor final class ScreenCorners {
    private var settings = ScreenCornerSettings.load()
    private var windows: [(window: NSWindow, screen: NSScreen)] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        rebuild()
    }

    private func settingsChanged() {
        let next = ScreenCornerSettings.load()
        guard next != settings else { return }   // other PanelLight settings also post this notification
        settings = next
        if windows.isEmpty, settings.enabled { rebuild() } else { refresh() }
    }

    private func rebuild() {
        windows.forEach { $0.window.orderOut(nil) }
        windows = []
        guard settings.enabled else { return }
        windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.animationBehavior = .none
            // Above the menu bar and the software dimmer (statusBar + 1), below the PanelLight panel (.popUpMenu).
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = CornerMaskView(frame: NSRect(origin: .zero, size: screen.frame.size))
            return (w, screen)
        }
        refresh()
    }

    private func refresh() {
        for (window, screen) in windows {
            if settings.enabled && (settings.external || Self.isBuiltIn(screen)) {
                (window.contentView as? CornerMaskView)?.settings = settings
                window.orderFrontRegardless()
            } else {
                window.orderOut(nil)
            }
        }
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

/// Settings section shown in PanelLight › Settings.
struct ScreenCornersSettingsView: View {
    @AppStorage(ScreenCornerKeys.enabled) private var enabled = false
    @AppStorage(ScreenCornerKeys.radius) private var radius = ScreenCornerKeys.defaultRadius
    @AppStorage(ScreenCornerKeys.smooth) private var smooth = false
    @AppStorage(ScreenCornerKeys.external) private var external = true
    @AppStorage(ScreenCornerKeys.top) private var top = true
    @AppStorage(ScreenCornerKeys.bottom) private var bottom = true

    private enum Which: Hashable { case all, top, bottom }
    private var which: Binding<Which> {
        Binding(get: { top && bottom ? .all : (top ? .top : .bottom) },
                set: { top = $0 != .bottom; bottom = $0 != .top })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Rounded screen corners", isOn: $enabled)
                .help("Draws rounded black corners on screens with square corners. Clicks pass through.")
            if enabled {
                Picker("Corners", selection: which) {
                    Text("All").tag(Which.all)
                    Text("Top").tag(Which.top)
                    Text("Bottom").tag(Which.bottom)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Text("Radius")
                    Slider(value: Binding(get: { radius }, set: { radius = $0.rounded() }), in: 0...60)
                    Text("\(Int(radius)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                if #available(macOS 14, *) {
                    Toggle("Smooth curve", isOn: $smooth)
                        .help("Uses Apple's continuous curve, like the hardware corners.")
                }
                Toggle("External displays", isOn: $external)
            }
        }
    }
}
