import AppKit
import SwiftUI

// Hovering the menu bar icon drops a black tab out of the menu bar, like the notch, with one brightness bar
// for the screen under the pointer. With Link on, the bar moves every display together. A click on the icon
// still opens the full panel.
@MainActor final class HoverDrop: NSResponder {
    // The bar sits `inset` from the top, sides and bottom alike; the bottom corner radius is concentric with its
    // 24 pt frame (12 + inset).
    static let depth: CGFloat = 38, shoulder: CGFloat = 18, inset: CGFloat = 7, barWidth: CGFloat = 146
    // Optional sloped sides (Settings › Appearance): the edge comes down from the menu bar in one soft slope
    // `slope` wide. The tab grows by that much; the bar keeps its width.
    static let slopedKey = "hoverDropSloped", slope: CGFloat = 36
    static var sloped: Bool { UserDefaults.standard.bool(forKey: slopedKey) }
    static var width: CGFloat { barWidth + 2 * inset + 2 * (sloped ? slope : shoulder) }
    static var radius: CGFloat { 12 + inset }
    // The outline runs on along the bottom edge of the menu bar this far on each side of the tab and fades out.
    // The window is that much wider; its clear wings let clicks through to the window below.
    static let wing: CGFloat = 64
    static var windowWidth: CGFloat { width + 2 * wing }

    private let model: MonitorModel
    private weak var statusButton: NSStatusBarButton?
    private let state = HoverDropState()
    private var panel: NSPanel?
    private var showWork: DispatchWorkItem?
    private var watch: Timer?
    private var outsideSince: Date?
    // Bumped on every show/hide so a finished collapse never hides a tab that was shown again meanwhile.
    private var generation = 0
    var suppressed: () -> Bool = { false }
    var onVisibility: (Bool) -> Void = { _ in }

    init(button: NSStatusBarButton, model: MonitorModel) {
        self.model = model
        statusButton = button
        super.init()
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        outsideSince = nil
        guard panel?.isVisible != true || !state.expanded else { return }
        showWork?.cancel()
        // A pointer just passing along the menu bar should not open and close the tab.
        let work = DispatchWorkItem { [weak self] in self?.show() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        startWatching()
    }

    override func mouseExited(with event: NSEvent) {
        guard panel?.isVisible != true else { return }
        showWork?.cancel()
        showWork = nil
        stopWatching()
    }

    private var iconFrame: NSRect? {
        guard let button = statusButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func show() {
        showWork = nil
        guard !suppressed(), let window = statusButton?.window, let icon = iconFrame,
              icon.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
        let screen = window.screen ?? NSScreen.main
        state.screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let bounds = screen?.frame ?? .zero
        // The tab's top edge sits on the bottom edge of the menu bar.
        let x = min(max(icon.midX - Self.windowWidth / 2, bounds.minX), bounds.maxX - Self.windowWidth)
        let popup = panel ?? makePanel()
        generation += 1
        popup.setFrame(NSRect(x: x, y: window.frame.minY - Self.depth, width: Self.windowWidth, height: Self.depth), display: false)
        popup.orderFrontRegardless()
        onVisibility(true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.async { [state] in
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.78)) {
                state.expanded = true
            }
        }
    }

    func hide(animated: Bool = true) {
        showWork?.cancel()
        showWork = nil
        stopWatching()
        guard let popup = panel, popup.isVisible else { state.expanded = false; return }
        generation += 1
        let current = generation
        onVisibility(false)
        guard animated else { state.expanded = false; popup.orderOut(nil); return }
        withAnimation(.easeIn(duration: 0.16)) { state.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.generation == current else { return }
            popup.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let popup = GlassPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = false
        popup.level = .popUpMenu
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        popup.hidesOnDeactivate = false
        popup.animationBehavior = .none
        popup.contentView = FirstClickHostingView(rootView: HoverBrightnessView(model: model, state: state))
        panel = popup
        return popup
    }

    // Stays open while the pointer is on the icon, on its way down, or on the tab, and while the bar is held;
    // closes a moment after the pointer leaves all of them.
    private func startWatching() {
        guard watch == nil else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stopWatching() {
        watch?.invalidate()
        watch = nil
        outsideSince = nil
    }

    private func check() {
        guard let popup = panel, popup.isVisible, let icon = iconFrame else {
            if showWork == nil { stopWatching() }
            return
        }
        if suppressed() { hide(animated: false); return }
        let mouse = NSEvent.mouseLocation
        let tab = popup.frame.insetBy(dx: Self.wing, dy: 0)
        let bridge = NSRect(x: icon.minX, y: tab.maxY - 1, width: icon.width, height: max(0, icon.minY - tab.maxY) + 2)
        if NSEvent.pressedMouseButtons != 0 || icon.insetBy(dx: -2, dy: -2).contains(mouse)
            || bridge.contains(mouse) || tab.contains(mouse) {
            outsideSince = nil
            return
        }
        if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.25 { hide() }
        } else {
            outsideSince = Date()
        }
    }
}

// macOS 26+ draws real Liquid Glass only in windows with the active appearance; the tab never becomes key
// (the app under the pointer keeps focus), so it reports the active appearance itself. Private AppKit hook,
// the same one SayWords uses; if macOS drops it, the glass falls back to a frosted look.
private final class GlassPanel: NSPanel {
    @objc(_hasActiveAppearance) func panelLightHasActiveAppearance() -> Bool { true }
}

final class HoverDropState: ObservableObject {
    @Published var expanded = false
    @Published var screenID: UInt32?
}

// The app is never frontmost while hovering; the first click must still reach the bar instead of being eaten.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct HoverBrightnessView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: HoverDropState
    @AppStorage("externalBarColor") private var externalBarColor = "#3489FC"
    @AppStorage("builtInBarColor") private var builtInBarColor = "#3489FC"
    @AppStorage(HoverDrop.slopedKey) private var sloped = false

    private struct Target {
        let title: String
        let value: Double?
        let enabled: Bool
        let tint: String
        let set: (Double) -> Void
    }

    // Link wins; otherwise the screen whose menu bar the pointer is on.
    private var target: Target {
        if model.linkBrightness && model.canLinkBrightness {
            return Target(title: String(localized: "All displays"), value: model.linkedBrightnessValue,
                          enabled: true, tint: externalBarColor) { model.setAllBrightness($0) }
        }
        if let builtIn = model.builtInDisplay, builtIn.id == state.screenID {
            return Target(title: builtIn.name, value: model.builtInBrightnessValue,
                          enabled: model.canChangeBuiltInBrightness, tint: builtInBarColor) { model.setBuiltInBrightness($0) }
        }
        if let display = model.displays.first(where: { $0.id == state.screenID }) {
            return Target(title: displayTitle(display),
                          value: model.brightness(of: display.id), enabled: model.canChangeBrightness(of: display.id),
                          tint: externalBarColor) { model.setBrightness($0, of: display.id) }
        }
        return Target(title: "PanelLight", value: nil, enabled: false, tint: externalBarColor) { _ in }
    }

    var body: some View {
        ZStack(alignment: .top) {
            DropWings().opacity(state.expanded ? 1 : 0)
            tab
        }
        .frame(width: HoverDrop.windowWidth, height: HoverDrop.depth, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var tab: some View {
        let target = target
        return ZStack(alignment: .top) {
            DropBackground(shape: DropShape(height: state.expanded ? HoverDrop.depth : HoverDrop.shoulder,
                                            shoulder: HoverDrop.shoulder, radius: HoverDrop.radius,
                                            slope: sloped ? HoverDrop.slope : 0))
                .opacity(state.expanded ? 1 : 0)
            // Only the bar; the full panel has the names, icons and percentages. VoiceOver still reads the name.
            ColorSlider(value: Binding(get: { target.value ?? 0 }, set: target.set), tint: barColor(target.tint),
                        enabled: target.enabled && target.value != nil,
                        label: String(localized: "\(target.title) brightness"),
                        snaps: model.linkBrightness && model.canLinkBrightness ? model.linkSnapPoints : [])
                .frame(width: HoverDrop.barWidth)
                .padding(.top, HoverDrop.inset)
            .opacity(state.expanded ? 1 : 0)
            .scaleEffect(state.expanded ? 1 : 0.92, anchor: .top)
        }
        .frame(width: HoverDrop.width, height: HoverDrop.depth, alignment: .top)
    }
}

// The outline's thin wings along the bottom edge of the menu bar on both sides of the tab. They fade outwards and
// meet the tab at the shoulder tips with the rim's own width and brightness.
struct DropWings: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(DropRim.tipOpacity)],
                                            startPoint: .leading, endPoint: .trailing))
                .frame(width: HoverDrop.wing)
            Color.clear.frame(width: HoverDrop.width)
            Rectangle().fill(LinearGradient(colors: [.white.opacity(DropRim.tipOpacity), .white.opacity(0)],
                                            startPoint: .leading, endPoint: .trailing))
                .frame(width: HoverDrop.wing)
        }
        .frame(height: DropRim.tip)
        .allowsHitTesting(false)
    }
}

// Liquid Glass darkening to black further down, so the top edge melts into the menu bar.
struct DropBackground: View {
    let shape: DropShape
    // Strength of the Liquid Glass (0–1); lower values soften the bending and warping of what is behind.
    static let glassLevel: Double = 0.35

    var body: some View {
        // macOS 26+: real Liquid Glass (.clear), which bends and warps the window behind without frosting it.
        // Earlier systems cover it with a blur that opens up from the top. The black ramps in on an eased curve,
        // so it never reads as a band.
        ZStack {
            if #available(macOS 26, *) {
                // The glass shape reaches above the window: Liquid Glass lights every edge, and the top edge's light
                // read as a line along the menu bar. Outside the window only the shoulder, side and bottom light stays.
                // The glass does not start at full strength either: a light see-through strip on top, Liquid Glass
                // fading in below it, then the black.
                Color.clear.glassEffect(.clear, in: LiftedDropShape(shape: shape))
                    .opacity(Self.glassLevel)
                    .mask(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                 .init(color: .white.opacity(0.15), location: 0.1),
                                                 .init(color: .white.opacity(0.55), location: 0.25),
                                                 .init(color: .white.opacity(0.9), location: 0.42),
                                                 .init(color: .white, location: 0.55)],
                                         startPoint: .top, endPoint: .bottom))
            } else {
                DropBlur(stops: [(0, 0), (0.08, 0.12), (0.22, 0.42), (0.4, 0.78), (0.58, 0.96), (0.7, 1)])
            }
            shape.fill(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                              .init(color: .black.opacity(0.04), location: 0.25),
                                              .init(color: .black.opacity(0.25), location: 0.42),
                                              .init(color: .black.opacity(0.6), location: 0.6),
                                              .init(color: .black.opacity(0.86), location: 0.8),
                                              .init(color: .black.opacity(0.95), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        // Outline: a band inside the tab. It starts at the tips of the shoulders, where they meet the menu bar,
        // and grows slowly thicker and brighter on the way down, thickest along the bottom edge. A stroke on the
        // edge lost its outer half to the window at the bottom, which left the corners looking heaviest.
        .overlay(DropRim(shape: shape).fill(LinearGradient(stops: [.init(color: .white.opacity(DropRim.tipOpacity), location: 0),
                                                                   .init(color: .white.opacity(0.22), location: 0.3),
                                                                   .init(color: .white.opacity(0.32), location: 0.6),
                                                                   .init(color: .white.opacity(0.44), location: 1)],
                                                           startPoint: .top, endPoint: .bottom),
                                            style: FillStyle(eoFill: true)))
    }
}

// The tab's edge band: the space between the outer shape and an inner one pulled in from the shoulders, sides
// and bottom (even-odd fill).
struct DropRim: Shape {
    var shape: DropShape
    // Width at the shoulder tips (where the wings join), where the shoulder curve ends, at the bottom of the sides
    // and along the bottom edge: thinnest at the top, thickest along the bottom.
    static let tip: CGFloat = 0.9, shoulder: CGFloat = 1, side: CGFloat = 1.25, bottom: CGFloat = 1.8
    // Brightness at the shoulder tips and where the wings meet the tab.
    static let tipOpacity: Double = 0.26

    var animatableData: CGFloat {
        get { shape.height }
        set { shape.height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = shape.path(in: rect)
        path.addPath(shape.path(in: rect, tip: Self.tip, shoulderInset: Self.shoulder, side: Self.side, bottom: Self.bottom))
        return path
    }
}

// The system material that blurs the apps behind the tab, revealed top to bottom by a mask. Other apps' pixels
// are only blurred by the window server, so the material's visibility is ramped rather than the blur radius
// (NSVisualEffectView.maskImage, public API).
struct DropBlur: NSViewRepresentable {
    // (location, visibility) pairs; location 0 is the top edge, 1 the bottom.
    let stops: [(CGFloat, CGFloat)]

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        let colors = stops.map { NSColor.black.withAlphaComponent($0.1) }
        var locations = stops.map { $0.0 }
        let gradient = NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB)
        // A drawing-handler image is redrawn at every size, so the mask stretches with the tab as it grows.
        view.maskImage = NSImage(size: NSSize(width: 8, height: 64), flipped: true) { rect in
            gradient?.draw(in: rect, angle: 90)
            return true
        }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// Joins the menu bar with long, soft shoulders; the bottom corners are continuous (squircle) curves.
// Its height grows while it opens.
struct DropShape: Shape {
    var height: CGFloat
    let shoulder: CGFloat
    let radius: CGFloat
    // When set, sloped sides: one soft S-curve this wide instead of shoulder, side and bottom corner.
    var slope: CGFloat = 0

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path { path(in: rect, tip: 0, shoulderInset: 0, side: 0, bottom: 0) }

    // For the inner edge of the rim: the shoulder curve ends `shoulderInset` further in (zero at its tip), the
    // sides move in by up to `side` on the way down, the bottom edge moves up by `bottom`.
    // `tip` is the rim's width at the shoulder tips, where it meets the menu bar; the top edge itself stays out of it.
    // `lift` moves the top edge up by that much, out of the window; only for the glass layer.
    func path(in rect: CGRect, tip t0: CGFloat, shoulderInset a: CGFloat, side ts: CGFloat, bottom tb: CGFloat,
              lift: CGFloat = 0) -> Path {
        if slope > 0 { return slopedPath(in: rect, tip: t0, side: ts, bottom: tb, lift: lift) }
        let s = shoulder, w = rect.width, h = max(height, s) - tb
        let r = max(0, min(radius - (ts + tb) / 2, h - s, (w - 2 * s - 2 * ts) / 2))
        // On the shoulders the control points sit closer to the corner than a circular arc's, so the curve turns
        // gradually. The bottom corners are true circular arcs (c), so the gap to the bar stays even there too.
        let k: CGFloat = 0.22, c: CGFloat = 0.4477
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -lift))
        if lift > 0 { path.addLine(to: CGPoint(x: 0, y: 0)) }
        if t0 > 0 { path.addLine(to: CGPoint(x: 0, y: t0)) }
        path.addCurve(to: CGPoint(x: s + a, y: s), control1: CGPoint(x: s * (1 - k * 1.7) + a / 2, y: t0 + a / 2),
                      control2: CGPoint(x: s + a, y: s * k * 1.7))
        path.addLine(to: CGPoint(x: s + ts, y: h - r))
        if r > 0 {
            path.addCurve(to: CGPoint(x: s + ts + r, y: h), control1: CGPoint(x: s + ts, y: h - r * c),
                          control2: CGPoint(x: s + ts + r * c, y: h))
        }
        path.addLine(to: CGPoint(x: w - s - ts - r, y: h))
        if r > 0 {
            path.addCurve(to: CGPoint(x: w - s - ts, y: h - r), control1: CGPoint(x: w - s - ts - r * c, y: h),
                          control2: CGPoint(x: w - s - ts, y: h - r * c))
        }
        path.addLine(to: CGPoint(x: w - s - a, y: s))
        path.addCurve(to: CGPoint(x: w, y: t0), control1: CGPoint(x: w - s - a, y: s * k * 1.7),
                      control2: CGPoint(x: w - s * (1 - k * 1.7) - a / 2, y: t0 + a / 2))
        if t0 > 0 { path.addLine(to: CGPoint(x: w, y: 0)) }
        if lift > 0 { path.addLine(to: CGPoint(x: w, y: -lift)) }
        path.closeSubpath()
        return path
    }
}

extension DropShape {
    // Sloped sides: leave the menu bar flat, come down in a long slope and settle flat onto the bottom edge
    // (concave on top, convex below). For the rim's inner edge the side moves in by `side`, the bottom up by
    // `bottom`, with width `tip` at the ends.
    func slopedPath(in rect: CGRect, tip t0: CGFloat, side ts: CGFloat, bottom tb: CGFloat, lift: CGFloat) -> Path {
        let w = rect.width, sw = slope, h = max(height - tb, t0 + 1)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -lift))
        if lift > 0 { path.addLine(to: CGPoint(x: 0, y: 0)) }
        if t0 > 0 { path.addLine(to: CGPoint(x: 0, y: t0)) }
        path.addCurve(to: CGPoint(x: sw + ts, y: h), control1: CGPoint(x: sw * 0.5 + ts * 0.5, y: t0),
                      control2: CGPoint(x: sw * 0.5 + ts, y: h))
        path.addLine(to: CGPoint(x: w - sw - ts, y: h))
        path.addCurve(to: CGPoint(x: w, y: t0), control1: CGPoint(x: w - sw * 0.5 - ts, y: h),
                      control2: CGPoint(x: w - sw * 0.5 - ts * 0.5, y: t0))
        if t0 > 0 { path.addLine(to: CGPoint(x: w, y: 0)) }
        if lift > 0 { path.addLine(to: CGPoint(x: w, y: -lift)) }
        path.closeSubpath()
        return path
    }
}

// The glass layer's shape: the tab's shape with its top edge moved out of the window.
struct LiftedDropShape: Shape {
    var shape: DropShape

    var animatableData: CGFloat {
        get { shape.height }
        set { shape.height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        shape.path(in: rect, tip: 0, shoulderInset: 0, side: 0, bottom: 0, lift: 8)
    }
}

func displayTitle(_ display: DisplayIdentity) -> String {
    guard display.isVirtual else { return display.name }
    if display.name.localizedCaseInsensitiveContains("Sidecar") { return "iPad" }
    return display.name.replacingOccurrences(of: " (AirPlay)", with: "")
}
