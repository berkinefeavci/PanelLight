import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SwiftUI

// Full-screen title strip: when the menu bar is revealed in a full-screen app, macOS slides the app's title strip
// (a separate 32 pt window holding the window buttons) down with it, on a plain grey background. This draws a
// click-through window over that strip showing the page underneath (captured live from the app's own window,
// which the strip does not cover in the capture), plus a glass capsule behind the window buttons that grows under
// the pointer. The window lets clicks through to the real buttons, so the capsule's dots are drawn exactly over them:
// their place is measured from the screen each time the strip appears (it differs per app) and remembered per app.
// Experimental; off by default; needs Screen Recording permission.
// It only polls while the pointer is near the top of a screen; otherwise it is idle.
enum FullscreenStripKeys {
    static let enabled = "fullscreenStripGlass"
    static let buttonsPrefix = "fullscreenStrip.buttons."   // + bundle id: [close x, zoom x, centre y, diameter]
}

/// Temporary diagnostics while the strip is experimental: /tmp/panellight-strip.log
func stripLog(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/panellight-strip.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

private struct StripTarget: Equatable {
    var pid: pid_t
    var mainID: CGWindowID
    var stripID: CGWindowID
    var displayID: CGDirectDisplayID
    var screenOrigin: CGPoint   // the screen's top-left in CG global coordinates
    var mainBounds: CGRect   // CG global coordinates (top-left origin)
    var stripBounds: CGRect
    var stripAlpha: Double
    /// On notched screens the full-screen window starts below the notch and the strip fades in at the window top;
    /// on others the strip sits hidden at the window top and slides down with the menu bar.
    var notched: Bool
    var revealed: Bool {
        guard stripAlpha > 0.01 else { return false }
        return notched || stripBounds.minY > mainBounds.minY + 0.5
    }
}

@MainActor final class FullscreenStrip {
    private var enabled = UserDefaults.standard.bool(forKey: FullscreenStripKeys.enabled)
    private var mouseMonitor: Any?
    private var layouts: [String: StripButtonLayout] = [:]
    // Button measuring, once per reveal. The strip slides into place with an animation the window list doesn't
    // show (its bounds are final at once), so wait a moment and retry while the buttons are still cut off or faded.
    private var revealStart: Date?
    private var measureDone = false
    private var measuring = false
    private var measureAttempts = 0
    private var nextMeasure = Date.distantPast
    private var forceHover = false                 // test hook
    private var timer: Timer?
    private var idleTicks = 0
    private var overlay: StripOverlayWindow?
    private var capture: AnyObject?          // StripCapture (macOS 12.3+)
    private var captureKey: (CGWindowID, CGRect)?
    private var hasFrame = false
    private var observer: NSObjectProtocol?

    init() {
        // Test hook: `PanelLight.stripPreview` shows the overlay for 6 s without waiting for the menu bar;
        // with object "hover" the capsule shows its hover state.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("PanelLight.stripPreview"),
                                                            object: nil, queue: .main) { [weak self] note in
            let hover = (note.object as? String) == "hover"
            MainActor.assumeIsolated { self?.preview(hover: hover) }
        }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        apply()
    }

    private func settingsChanged() {
        let next = UserDefaults.standard.bool(forKey: FullscreenStripKeys.enabled)
        guard next != enabled else { return }
        enabled = next
        apply()
    }

    private func apply() {
        if enabled {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
            stripLog("enabled, screen recording preflight=\(CGPreflightScreenCaptureAccess())")
            if #available(macOS 12.3, *) { StripCapture.requestAccess() }
        } else {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            stopTracking(); releaseCapture()
        }
    }

    private func mouseMoved() {
        guard timer == nil, Self.pointerNearTop(within: 200) else { return }
        idleTicks = 0
        stripLog("tracking start")
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        holdAwake()
        tick()
    }

    // App Nap slows a background app's timers; the strip was noticed ~150 ms late. Stay awake while tracking.
    private var activity: NSObjectProtocol?
    private func holdAwake() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Following the full-screen title strip")
        }
    }

    private var previewUntil = Date.distantPast
    private func preview(hover: Bool) {
        stripLog("preview requested hover=\(hover)")
        forceHover = hover
        previewUntil = Date().addingTimeInterval(6)
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            holdAwake()
        }
        idleTicks = 0
        tick()
    }

    private var lastState = ""
    private var lastTarget: StripTarget?
    private var missingTicks = 0

    private func tick() {
        let found = Self.findTarget()
        // While the menu bar animates the window list can drop the strip for a frame; keep the last one briefly
        // instead of hiding and showing the overlay again (it flickered).
        if found != nil { missingTicks = 0; lastTarget = found } else { missingTicks += 1 }
        let target = found ?? (missingTicks <= 10 ? lastTarget : nil)
        let state = target.map { "target main=\($0.mainID) \($0.mainBounds) strip=\($0.stripBounds) a=\($0.stripAlpha) notched=\($0.notched) revealed=\($0.revealed) hasFrame=\(hasFrame)" } ?? "no target"
        if state != lastState { lastState = state; stripLog(state) }
        // Start capturing as the pointer nears the top, so the first frame is ready when the strip appears.
        if let target, target.revealed || Self.pointerNearTop(within: 200) || Date() < previewUntil { ensureCapture(for: target) }
        if let target, target.revealed || Date() < previewUntil {
            idleTicks = 0
            measureButtons(target)
            showOverlay(for: target)
            return
        }
        revealStart = nil
        measureDone = false
        measureAttempts = 0
        hideOverlay()
        if (Self.pointerNearTop(within: 200) && target != nil) || Date() < previewUntil { idleTicks = 0; return }
        idleTicks += 1
        if idleTicks > 45 { stopTracking() }     // ~0.75 s after the strip went away
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        overlay?.hideButtons()
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        hideOverlay()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        lastTarget = nil
        missingTicks = 0
        // Keep the capture warm for a while: restarting it took ~150 ms, during which the grey strip showed.
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseCapture() }
        }
    }

    private var releaseTimer: Timer?

    private func releaseCapture() {
        guard timer == nil else { return }
        if #available(macOS 12.3, *) { (capture as? StripCapture)?.stop() }
        capture = nil
        captureKey = nil
        hasFrame = false
    }

    private func ensureCapture(for target: StripTarget) {
        guard #available(macOS 12.3, *) else { return }
        // Capture the screen band from the window top, leaving out the strip and PanelLight's own windows,
        // and shift it under the strip as it moves. (Capturing the app window alone still includes the strip.)
        let rect = CGRect(x: target.mainBounds.minX - target.screenOrigin.x, y: target.mainBounds.minY - target.screenOrigin.y,
                          width: target.mainBounds.width, height: Self.bandHeight)
        if let key = captureKey, key.0 == target.stripID, key.1 == rect { return }
        if overlay == nil { overlay = StripOverlayWindow() }
        (capture as? StripCapture)?.stop()
        hasFrame = false
        captureKey = (target.stripID, rect)
        let scale = Self.fullScreen(of: target.mainBounds)?.screen.backingScaleFactor ?? 2
        var current: StripCapture?
        let c = StripCapture { [weak self] box in
            // A stopped stream can still deliver a late frame; ignore anything but the live capture.
            guard let self, let current, self.capture === current else { return }
            self.overlay?.setPage(box.surface)
            if !self.hasFrame { self.hasFrame = true; stripLog("first frame"); self.tick() }
        }
        c.start(displayID: target.displayID, excluding: target.stripID, sourceRect: rect, scale: scale)
        current = c
        capture = c
    }

    private func showOverlay(for target: StripTarget) {
        guard hasFrame else { return }   // until the first captured frame arrives, leave the strip as is
        let w = overlay ?? StripOverlayWindow()
        overlay = w
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let s = target.stripBounds
        let frame = NSRect(x: s.minX, y: primaryHeight - s.maxY, width: s.width, height: s.height)
        if w.frame != frame { w.setFrame(frame, display: true) }
        w.place(bandHeight: Self.bandHeight, offset: s.minY - target.mainBounds.minY)
        if !w.isVisible {
            w.orderFrontRegardless()
            stripLog("overlay shown frame=\(w.frame)")
        }
        showButtons(for: target, in: w)
    }

    // MARK: Buttons

    private func showButtons(for target: StripTarget, in w: StripOverlayWindow) {
        // Until this app's buttons have been measured once, show none rather than dots beside the real ones.
        let previewing = Date() < previewUntil
        // On notched screens the strip fades in and out; the capsule follows its opacity.
        let alpha = previewing ? 1 : (target.notched ? CGFloat(target.stripAlpha) : 1)
        w.showButtons(layout(for: Self.appKey(target.pid)), alpha: alpha, forceHover: previewing && forceHover)
    }

    private static func appKey(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid.\(pid)"
    }

    private func layout(for key: String) -> StripButtonLayout? {
        if let l = layouts[key] { return l }
        guard let saved = UserDefaults.standard.array(forKey: FullscreenStripKeys.buttonsPrefix + key) as? [Double],
              let l = StripButtonLayout(stored: saved) else { return nil }
        layouts[key] = l
        return l
    }

    /// Once per reveal, after the strip has settled, find where this app's real buttons are.
    private func measureButtons(_ t: StripTarget) {
        guard t.revealed else { return }
        if revealStart == nil { revealStart = Date() }
        let key = Self.appKey(t.pid)
        guard #available(macOS 14, *) else {
            if layouts[key] == nil { layouts[key] = .standard }
            return
        }
        guard !measureDone, !measuring, measureAttempts < 8, t.stripAlpha > 0.99,
              let start = revealStart, Date().timeIntervalSince(start) > 0.35, Date() >= nextMeasure else { return }
        measuring = true
        measureAttempts += 1
        let rect = CGRect(x: t.stripBounds.minX - t.screenOrigin.x, y: t.stripBounds.minY - t.screenOrigin.y,
                          width: min(200, t.stripBounds.width), height: t.stripBounds.height)
        let scale = Self.fullScreen(of: t.mainBounds)?.screen.backingScaleFactor ?? 2
        let displayID = t.displayID
        let attempt = measureAttempts
        Task { [weak self] in
            let found = await StripButtonProbe.measure(displayID: displayID, rect: rect, scale: scale)
            guard let self else { return }
            self.measuring = false
            stripLog("buttons \(key) try \(attempt): \(found.map { "\($0)" } ?? "not found")")
            if let found {
                self.measureDone = true
                if self.layouts[key] != found {
                    self.layouts[key] = found
                    UserDefaults.standard.set(found.stored, forKey: FullscreenStripKeys.buttonsPrefix + key)
                }
            } else {
                self.nextMeasure = Date().addingTimeInterval(0.2)
                // Never measured and still nothing: show the usual place rather than no buttons at all.
                if attempt >= 8, self.layout(for: key) == nil { self.layouts[key] = .standard }
            }
        }
    }

    private static let bandHeight: CGFloat = 96

    // MARK: Window discovery

    private static func pointerNearTop(within distance: CGFloat) -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        return screen.frame.maxY - p.y < distance
    }

    /// The screen a full-screen window fills: same width and bottom, top at the screen top or just under the notch.
    private static func fullScreen(of cgRect: CGRect) -> (screen: NSScreen, notched: Bool)? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for s in NSScreen.screens {
            let f = s.frame
            let cg = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let gap = cgRect.minY - cg.minY
            if cgRect.minX == cg.minX, cgRect.width == cg.width, abs(cgRect.maxY - cg.maxY) < 0.5, gap >= 0, gap <= 50 {
                return (s, gap > 0.5)
            }
        }
        return nil
    }

    /// A full-screen window on screen and its title strip (a thin window of the same app and width, in front of it).
    /// Taken from the window list rather than `frontmostApplication`, which PanelLight sometimes saw late.
    /// With several full-screen screens, the one under the pointer wins.
    private static func findTarget() -> StripTarget? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var strips: [(pid: pid_t, bounds: CGRect, alpha: Double, id: CGWindowID)] = []
        var found: [(target: StripTarget, screen: NSScreen)] = []
        for info in list {   // front to back
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if (16...60).contains(bounds.height) { strips.append((pid, bounds, alpha, id)); continue }
            guard let full = fullScreen(of: bounds) else { continue }
            guard !found.contains(where: { $0.screen == full.screen }) else { continue }   // only the front one per screen
            guard let strip = strips.first(where: { $0.pid == pid && $0.bounds.minX == bounds.minX && $0.bounds.width == bounds.width
                                                    && $0.bounds.minY >= bounds.minY && $0.bounds.minY <= bounds.minY + 60 })
            else { continue }
            let number = full.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let target = StripTarget(pid: pid, mainID: id, stripID: strip.id, displayID: number?.uint32Value ?? 0,
                                     screenOrigin: CGPoint(x: full.screen.frame.minX, y: primaryHeight - full.screen.frame.maxY),
                                     mainBounds: bounds, stripBounds: strip.bounds,
                                     stripAlpha: strip.alpha, notched: full.notched)
            found.append((target, full.screen))
        }
        let mouse = NSEvent.mouseLocation
        return (found.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) ?? found.first)?.target
    }
}

// MARK: Overlay

private final class StripOverlayWindow: NSWindow {
    private let pageLayer = CALayer()
    private let capsule = StripButtonsCapsule(frame: NSRect(x: 0, y: 0, width: 100, height: 32))

    // Look like the active window, as the strip it replaces does: in a window drawn as inactive, Liquid Glass loses
    // its bright rim and lensing and turns into a flat grey shape. The window still never becomes key.
    @objc var hasKeyAppearance: Bool { true }
    @objc var hasMainAppearance: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 32), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        // Above the app's strip (normal level), below the menu bar so the menu bar still covers it while sliding.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        pageLayer.contentsGravity = .resize
        pageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.layer?.addSublayer(pageLayer)
        contentView = root
        capsule.frame = root.bounds
        capsule.autoresizingMask = [.width, .height]
        capsule.isHidden = true
        root.addSubview(capsule)
    }

    /// Shows the capsule over the real buttons (nil: not measured yet, show none). `alpha` follows the strip's fade.
    func showButtons(_ layout: StripButtonLayout?, alpha: CGFloat, forceHover: Bool) {
        guard let layout else { hideButtons(); return }
        let h = frame.height
        let center = NSPoint(x: layout.centers[1], y: h - layout.centerY)
        capsule.configure(layout: layout, center: center, maxHeight: 2 * min(center.y, h - center.y) - 1)
        if capsule.alphaValue != alpha { capsule.alphaValue = alpha }
        capsule.isHidden = false
        let m = NSEvent.mouseLocation
        capsule.hovered = forceHover || capsule.contains(NSPoint(x: m.x - frame.minX, y: m.y - frame.minY))
    }

    func hideButtons() {
        guard !capsule.isHidden else { return }
        capsule.isHidden = true
        capsule.reset()
    }

    /// The captured band starts at the page top; the strip sits `offset` points below it.
    func place(bandHeight: CGFloat, offset: CGFloat) {
        let h = frame.height
        let target = CGRect(x: 0, y: h + offset - bandHeight, width: frame.width, height: bandHeight)
        guard pageLayer.frame != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = target
        CATransaction.commit()
    }

    func setPage(_ surface: IOSurfaceRef) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = surface
        CATransaction.commit()
    }
}

// MARK: Buttons

/// Where an app's real window buttons sit in its full-screen strip, in points from the strip's top-left.
struct StripButtonLayout: Equatable, Sendable, CustomStringConvertible {
    var centers: [CGFloat]   // close, minimize, zoom
    var centerY: CGFloat
    var diameter: CGFloat

    /// Measured on Spotify (macOS 26); used only until an app is measured.
    static let standard = StripButtonLayout(centers: [26.75, 49.75, 72.75], centerY: 16, diameter: 14)

    init(centers: [CGFloat], centerY: CGFloat, diameter: CGFloat) {
        self.centers = centers
        self.centerY = centerY
        self.diameter = diameter
    }

    init?(stored a: [Double]) {
        guard a.count == 4, a.allSatisfy({ $0.isFinite }), a[1] > a[0], a[3] > 4, a[3] < 40 else { return nil }
        self.init(centers: [a[0], (a[0] + a[1]) / 2, a[1]], centerY: a[2], diameter: a[3])
    }

    var stored: [Double] { [centers[0], centers[2], centerY, diameter].map { Double($0) } }
    var description: String { String(format: "x %.2f / %.2f / %.2f  y %.2f  d %.2f", centers[0], centers[1], centers[2], centerY, diameter) }
}

/// Finds the real close (red) and zoom (green) buttons in a capture of the strip's left end.
enum StripButtonProbe {
    @available(macOS 14, *)
    static func measure(displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat) async -> StripButtonLayout? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let me = getpid()
            let excluded = content.windows.filter { $0.owningApplication?.processID == me }
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int((rect.width * scale).rounded())
            config.height = Int((rect.height * scale).rounded())
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
            return detect(image: image, scale: CGFloat(image.width) / rect.width)
        } catch {
            stripLog("buttons: capture failed \(error)")
            return nil
        }
    }

    static func detect(image: CGImage, scale: CGFloat) -> StripButtonLayout? {
        let w = image.width, h = image.height, row = w * 4
        var pixels = [UInt8](repeating: 0, count: row * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? detect(bgra: pixels, width: w, height: h, bytesPerRow: row, scale: scale) : nil
    }

    /// BGRA rows from the top. Returns nil unless both discs are found side by side at a plausible size.
    static func detect(bgra p: [UInt8], width: Int, height: Int, bytesPerRow: Int, scale: CGFloat) -> StripButtonLayout? {
        struct Box {
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
            mutating func add(_ x: Int, _ y: Int) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
            }
            var midX: CGFloat { CGFloat(minX + maxX + 1) / 2 }
            var midY: CGFloat { CGFloat(minY + maxY + 1) / 2 }
            var size: CGFloat { CGFloat(max(maxX - minX, maxY - minY) + 1) }
            var isRound: Bool { abs((maxX - minX) - (maxY - minY)) <= max(2, (maxX - minX) / 6) }
        }
        var red = Box(), green = Box()
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
                if r > 180, r - g > 70, r - b > 70 { red.add(x, y) }
                else if g > 140, g - r > 50, g - b > 40 { green.add(x, y) }
            }
        }
        let minCount = Int(20 * scale * scale)
        stripLog("buttons: red \(red.count) px at \(red.minX)-\(red.maxX)/\(red.minY)-\(red.maxY), green \(green.count) px at \(green.minX)-\(green.maxX)/\(green.minY)-\(green.maxY), image \(width)x\(height)")
        guard red.count >= minCount, green.count >= minCount else { return nil }
        let d = (red.size + green.size) / 2 / scale
        let gap = (green.midX - red.midX) / scale
        // Whole, round discs only: while the strip slides in they are cut off at the top.
        guard (8...26).contains(d), abs(red.size - green.size) / scale < 4, (30...80).contains(gap),
              abs(red.midY - green.midY) / scale < 3, red.isRound, green.isRound,
              red.minY > 0, green.minY > 0, red.maxY < height - 1, green.maxY < height - 1 else { return nil }
        let r = red.midX / scale, g = green.midX / scale
        return StripButtonLayout(centers: [r, (r + g) / 2, g], centerY: (red.midY + green.midY) / 2 / scale, diameter: d)
    }
}

/// The real macOS window buttons, drawn by AppKit itself in a hidden titled window: at rest, and with the pointer
/// over the group (× − and the full-screen symbol). Drawn once at 6×; the hover set follows after the system's
/// reveal animation (~0.3 s). If the hover call ever stops working, the buttons simply show no symbols.
@MainActor enum StripButtonArt {
    private(set) static var normal: [CGImage] = []
    private(set) static var hover: [CGImage] = []
    private static var window: NSWindow?
    private static var waiting: [() -> Void] = []

    private final class ActiveLookWindow: NSWindow {
        @objc var hasKeyAppearance: Bool { true }   // colours instead of the grey inactive buttons
        @objc var hasMainAppearance: Bool { true }
    }

    /// Calls `ready` when the hover set is there (now, if it already is); the rest set is there on return.
    static func prepare(_ ready: @escaping @MainActor () -> Void) {
        if !hover.isEmpty { ready(); return }
        waiting.append(ready)
        guard window == nil else { return }
        let w = ActiveLookWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 120, height: 40),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.collectionBehavior = [.fullScreenPrimary]   // green shows the full-screen symbol, not the zoom "+"
        window = w
        w.display()
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
        normal = buttons.compactMap(draw)
        let enter = NSSelectorFromString("mouseEnteredLeftButtonGroup")
        if let frame = w.contentView?.superview, frame.responds(to: enter) { frame.perform(enter) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let shown = buttons.compactMap(draw)
            hover = shown.count == normal.count ? shown : normal
            stripLog("button art: \(normal.count) buttons, symbols \(shown.count == normal.count ? "drawn" : "missing")")
            window = nil
            let calls = waiting
            waiting = []
            calls.forEach { $0() }
        }
    }

    private static func draw(_ b: NSButton) -> CGImage? {
        let s = 6
        guard b.bounds.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(b.bounds.width) * s, pixelsHigh: Int(b.bounds.height) * s,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.bounds.size
        b.needsDisplay = true
        b.cacheDisplay(in: b.bounds, to: rep)
        return rep.cgImage
    }
}

/// Liquid-glass capsule with the three window buttons. Under the pointer the glass and the buttons grow on a spring
/// and the buttons show their symbols. The buttons grow around their own centres, which stay on the real buttons;
/// the glass grows up to the strip's height so nothing cuts it off. It lives in the opaque strip window on purpose:
/// in a transparent window the glass picked up the buttons and spread a coloured haze around each one.
private final class StripButtonsCapsule: NSView {
    private let glass: NSView
    private let dotsHost = NSView()
    private var dots: [CALayer] = []
    private var glyphs: [CALayer] = []   // the same button with its symbol, faded in on top
    private var offsets: [CGFloat] = [-23, 0, 23]
    private var diameter: CGFloat = 14
    private var center = NSPoint.zero
    private var maxHeight: CGFloat = 31

    // Spring state: 0 = rest, 1 = hovered.
    private var value: CGFloat = 0
    private var velocity: CGFloat = 0
    private var goal: CGFloat = 0
    private var timer: Timer?
    private var lastStep: CFTimeInterval = 0

    var hovered = false {
        didSet { if hovered != oldValue { goal = hovered ? 1 : 0; animate() } }
    }

    override init(frame: NSRect) {
        if #available(macOS 26, *) {
            glass = NSGlassEffectView()
        } else {
            let v = NSVisualEffectView()
            v.blendingMode = .withinWindow
            v.material = .hudWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            glass = v
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        addSubview(glass)

        dotsHost.frame = bounds
        dotsHost.autoresizingMask = [.width, .height]
        dotsHost.wantsLayer = true
        addSubview(dotsHost)
        let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                                        "contents": NSNull(), "opacity": NSNull()]
        for _ in 0..<3 {
            let d = CALayer(), g = CALayer()
            for l in [d, g] {
                l.actions = none
                l.contentsGravity = .resize
                l.minificationFilter = .trilinear
            }
            g.opacity = 0
            d.addSublayer(g)
            dotsHost.layer?.addSublayer(d)
            dots.append(d)
            glyphs.append(g)
        }
        StripButtonArt.prepare { [weak self] in self?.applyArt() }
        applyArt()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyArt() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in dots.indices {
            dots[i].contents = StripButtonArt.normal.indices.contains(i) ? StripButtonArt.normal[i] : nil
            glyphs[i].contents = StripButtonArt.hover.indices.contains(i) ? StripButtonArt.hover[i] : nil
        }
        CATransaction.commit()
    }

    /// `maxHeight`: the tallest the capsule may grow and still fit the strip around `center`.
    func configure(layout: StripButtonLayout, center: NSPoint, maxHeight: CGFloat) {
        let offsets = layout.centers.map { $0 - layout.centers[1] }
        guard offsets != self.offsets || layout.diameter != diameter || center != self.center || maxHeight != self.maxHeight
        else { return }
        self.offsets = offsets
        diameter = layout.diameter
        self.center = center
        self.maxHeight = maxHeight
        layoutParts()
    }

    func reset() {
        hovered = false
        timer?.invalidate()
        timer = nil
        value = 0
        velocity = 0
        goal = 0
        layoutParts()
    }

    /// Hover test with some slack, more once grown, so the edge doesn't flicker.
    func contains(_ p: NSPoint) -> Bool {
        hovered ? geometry(1).capsule.insetBy(dx: -6, dy: -6).contains(p) : geometry(0).capsule.insetBy(dx: -1, dy: -1).contains(p)
    }

    private func geometry(_ t: CGFloat) -> (capsule: CGRect, dot: CGFloat) {
        let d = diameter * (1 + 0.32 * t)            // 14 → ~18.5 pt
        let pad = 6 + 4 * t                          // glass beyond the outer dots
        let h = min(d + 12 + 5 * t, max(d + 4, maxHeight))   // 26 → up to the strip's height
        let w = (offsets.last ?? 0) - (offsets.first ?? 0) + d + 2 * pad
        return (CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), d)
    }

    private func layoutParts() {
        let g = geometry(value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = g.capsule
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = g.capsule.height / 2
        } else {
            glass.layer?.cornerRadius = g.capsule.height / 2
        }
        let d = g.dot
        for (i, dot) in dots.enumerated() where i < offsets.count {
            dot.frame = CGRect(x: center.x + offsets[i] - d / 2, y: center.y - d / 2, width: d, height: d)
            glyphs[i].frame = CGRect(x: 0, y: 0, width: d, height: d)
            glyphs[i].opacity = Float(min(1, max(0, value * 1.4 - 0.25)))
        }
        CATransaction.commit()
    }

    private func animate() {
        guard timer == nil else { return }
        lastStep = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Slightly under-damped spring (~0.3 s, a few percent overshoot), restartable mid-flight.
    private func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30.0, now - lastStep))
        lastStep = now
        let stiffness: CGFloat = 420, damping: CGFloat = 30
        velocity += (-stiffness * (value - goal) - damping * velocity) * dt
        value += velocity * dt
        if abs(value - goal) < 0.002, abs(velocity) < 0.02 {
            value = goal
            velocity = 0
            timer?.invalidate()
            timer = nil
        }
        layoutParts()
    }
}

// MARK: Capture

struct SurfaceBox: @unchecked Sendable { let surface: IOSurfaceRef }

@available(macOS 12.3, *)
private final class StripCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PanelLight.strip-capture")
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private let onFrame: @Sendable (SurfaceBox) -> Void

    init(onFrame: @escaping @MainActor @Sendable (SurfaceBox) -> Void) {
        self.onFrame = { box in DispatchQueue.main.async { MainActor.assumeIsolated { onFrame(box) } } }
    }

    /// Asking for shareable content once shows the Screen Recording prompt when PanelLight is not allowed yet.
    static func requestAccess() {
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
    }

    func start(displayID: CGDirectDisplayID, excluding stripID: CGWindowID, sourceRect: CGRect, scale: CGFloat) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    stripLog("capture: display \(displayID) not found"); return
                }
                let me = getpid()
                let excluded = content.windows.filter { $0.windowID == stripID || $0.owningApplication?.processID == me }
                stripLog("capture: display \(displayID) rect=\(sourceRect) excluding \(excluded.count) windows")
                let config = SCStreamConfiguration()
                config.sourceRect = sourceRect
                config.width = Int(sourceRect.width * scale)
                config.height = Int(sourceRect.height * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 3
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                guard adopt(s) else { return }
                try await s.startCapture()
            } catch {
                stripLog("capture failed: \(error)")
            }
        }
    }

    private func adopt(_ s: SCStream) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        stream = s
        return true
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = stream
        stream = nil
        lock.unlock()
        if let s { Task { try? await s.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        onFrame(SurfaceBox(surface: surface))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stripLog("capture stopped: \(error)")
    }
}

/// Settings row shown in PanelLight › Settings.
struct FullscreenStripSettingsView: View {
    @AppStorage(FullscreenStripKeys.enabled) private var enabled = false

    var body: some View {
        Toggle("Glass title strip in full screen", isOn: $enabled)
            .help("Experimental. Hides the grey strip that slides down with the menu bar in full-screen apps and puts the window buttons on a glass capsule. Needs Screen Recording permission.")
    }
}
