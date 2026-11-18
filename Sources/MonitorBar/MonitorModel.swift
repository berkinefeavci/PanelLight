import AppKit
import Combine
import DDCBridge
import ServiceManagement

// Where the message on screen came from, so it goes away when that condition recovers.
enum IssueSource: Equatable {
    case keyboardUnavailable, builtInUnavailable, display, other
}

@MainActor final class MonitorModel: ObservableObject {
    @Published private(set) var displays: [DisplayIdentity] = []
    @Published private(set) var probes: [DDCProbe] = []
    // External screens without DDC/CI brightness (Sidecar, AirPlay, unresponsive monitors) dimmed by overlay.
    @Published private(set) var softwareDimmed: Set<UInt32> = []
    @Published private(set) var builtInDisplay: DisplayIdentity?
    @Published private(set) var builtInBrightnessValue: Double?
    @Published private(set) var keyboardBrightnessValue: Double?
    @Published private(set) var nightShiftWarm: Bool?
    @Published private(set) var linkBrightness = UserDefaults.standard.bool(forKey: "linkBrightness")
    @Published private(set) var contrastValue = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemError: String?
    // Monitors that answer DDC/CI but keep a control fixed (HDR, picture mode, …), learned from writes they ignore.
    // Their contrast goes through the gamma table and their brightness through the overlay, until the display is
    // reconnected or Refresh in Settings is pressed.
    @Published private(set) var contrastLocked: Set<UInt32> = []
    @Published private(set) var brightnessLocked: Set<UInt32> = []

    private let discovery = DisplayDiscovery()
    private var brightnessQueues: [UInt32: LatestWriteQueue] = [:]
    private var contrastQueues: [UInt32: LatestWriteQueue] = [:]
    private let contrastScheduler = WriteScheduler()
    private let builtInScheduler = WriteScheduler()
    private let keyboardScheduler = WriteScheduler()
    private let gamma = GammaContrastController()
    private let dimmer = SoftwareDimmer()
    // Link's own overlay: dims a screen below its lowest hardware light, all the way to black.
    private let linkDimmer = SoftwareDimmer(maximumDim: 1)
    @Published private(set) var linkedLevel = 50.0
    @Published private(set) var nitRevision = 0
    private var generation = 0
    private var brightnessRequests: [UInt32: Int] = [:]
    private var contrastRequest = 0
    private var builtInRequest = 0
    private var keyboardRequest = 0
    private var keyboardWritePending = false
    private var builtInWritePending = false
    private var builtInContrastFailed = false
    private var errorSource: IssueSource?
    // A probe is running; the same display list does not start another one.
    private var isProbing = false
    private var nightShiftEnabledBeforeOverride: Bool?
    private var pollTimer: Timer?
    private var isPanelVisible = false
    private var lastMirroredBuiltIn: Double?
    private var ignoredBrightnessWrites: [UInt32: Int] = [:]
    private var requestedBrightness: [UInt32: Double] = [:]

    // Rows stay usable while a refresh re-reads the monitors; only the first probe has nothing to show.
    var canChangeContrast: Bool { probes.contains { $0.contrast != nil } }
    var canChangeBuiltInBrightness: Bool { builtInDisplay != nil && builtInBrightnessValue != nil }
    var canChangeKeyboardBrightness: Bool { keyboardBrightnessValue != nil }
    var canLinkBrightness: Bool {
        (canChangeBuiltInBrightness ? 1 : 0) + probes.filter { $0.brightness != nil }.count >= 2
    }

    // Shown on the single bar while all screens are linked: the shared level in nits (see NitMatch).
    var linkedBrightnessValue: Double? { canLinkBrightness ? linkedLevel : nil }

    // MARK: Matched brightness

    /// Screens Link drives by nits: the Mac and every monitor with hardware (DDC/CI) brightness.
    var nitDisplays: [(display: DisplayIdentity, builtIn: Bool)] {
        var items: [(DisplayIdentity, Bool)] = []
        if let builtInDisplay, canChangeBuiltInBrightness { items.append((builtInDisplay, true)) }
        for probe in probes where probe.brightness != nil && !softwareDimmed.contains(probe.display.id) {
            items.append((probe.display, false))
        }
        return items
    }

    func nitProfile(_ display: DisplayIdentity, builtIn: Bool) -> NitProfile {
        NitProfiles.load(display, builtIn: builtIn)
    }

    func setNitProfile(_ profile: NitProfile, for display: DisplayIdentity, builtIn: Bool) {
        guard profile.minNits >= 0, profile.maxNits > profile.minNits else { return }
        NitProfiles.save(profile, for: display, builtIn: builtIn)
        nitRevision += 1
        if linkBrightness { setAllBrightness(linkedLevel) }
    }

    private var topNits: Double {
        nitDisplays.map { nitProfile($0.display, builtIn: $0.builtIn).maxNits }.max() ?? 0
    }

    /// Bar positions where a monitor reaches its maximum; the bar snaps there.
    var linkSnapPoints: [Double] {
        let top = topNits
        return nitDisplays.filter { !$0.builtIn }.compactMap { item in
            let level = NitMatch.level(forNits: nitProfile(item.display, builtIn: false).maxNits, top: top)
            return level < 99.5 ? level : nil
        }
    }

    func brightness(of id: UInt32) -> Double? {
        probes.first { $0.display.id == id }?.brightness?.percent
    }

    func canChangeBrightness(of id: UInt32) -> Bool { brightness(of: id) != nil }

    func start() {
        LegacySettings.removeObsoleteKeys()
        GammaContrastController.recoverAfterCrash()
        readLoginItem()
        discovery.onChange = { [weak self] displays, force in
            MainActor.assumeIsolated { self?.updateDisplays(displays, force: force) }
        }
        discovery.start()
        pollKeyboardBrightness()
        pollNightShift()
        updatePolling()
    }

    func stop() {
        cancelPendingWrites()
        contrastScheduler.cancel()
        builtInScheduler.cancel()
        keyboardScheduler.cancel()
        builtInWritePending = false
        keyboardWritePending = false
        pollTimer?.invalidate()
        pollTimer = nil
        gamma.restoreAll()
        dimmer.removeAll()
        linkDimmer.removeAll()
        discovery.stop()
    }

    @available(macOS 13, *)
    func setLaunchAtLogin(_ enabled: Bool) {
        var changeFailed = false
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            changeFailed = true
        }
        readLoginItem(wanted: changeFailed ? enabled : nil)
    }

    // Reads the real state again: the user can change it in System Settings > Login Items at any time.
    // `wanted` is set after a failed register/unregister; the error only counts if the state is not what was asked for.
    func readLoginItem(wanted: Bool? = nil) {
        guard #available(macOS 13, *) else { return }
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled
        let needsApproval = status == .requiresApproval
        let failed = wanted.map { $0 != enabled && !needsApproval } ?? false
        let error = failed ? String(localized: "Open at login could not be changed") : nil
        if launchAtLogin != enabled { launchAtLogin = enabled }
        if loginItemNeedsApproval != needsApproval { loginItemNeedsApproval = needsApproval }
        if loginItemError != error { loginItemError = error }
    }

    // Opening the panel refreshes too. Only Refresh in Settings forgets the locked controls, so a monitor whose
    // picture mode was changed gets its hardware controls back without every panel opening testing them again.
    func refresh(retryLockedControls: Bool = false) {
        clearError()
        readLoginItem()
        if retryLockedControls { forgetLockedControls() }
        updateDisplays(DisplayDiscovery.externalDisplays(), force: true)
    }

    private func forgetLockedControls() {
        for id in contrastLocked { gamma.restore(id) }
        if !contrastLocked.isEmpty { contrastLocked = [] }
        if !brightnessLocked.isEmpty { brightnessLocked = [] }
        ignoredBrightnessWrites = [:]
    }

    // The panel shows one message at a time; every change below publishes only when the text really changes.
    func report(_ message: String, source: IssueSource = .other) {
        if errorMessage != message { errorMessage = message }
        errorSource = source
    }

    func clearError(from source: IssueSource? = nil) {
        guard errorMessage != nil, source == nil || errorSource == source else { return }
        errorMessage = nil
        errorSource = nil
    }

    func setLinkBrightness(_ enabled: Bool) {
        linkBrightness = enabled
        UserDefaults.standard.set(enabled, forKey: "linkBrightness")
        lastMirroredBuiltIn = builtInBrightnessValue
        if enabled { followBuiltIn(force: true) } else { linkDimmer.removeAll() }
        updatePolling()
    }

    func setBrightness(_ value: Double, of id: UInt32) {
        if linkBrightness {
            setAllBrightness(value)
        } else {
            setExternalBrightness(value, of: id)
        }
    }

    func setBuiltInBrightness(_ value: Double) {
        if linkBrightness {
            setAllBrightness(value)
        } else {
            setBuiltInBrightnessOnly(value)
            lastMirroredBuiltIn = min(100, max(0, value))
        }
    }

    func setAllBrightness(_ value: Double) {
        linkedLevel = min(100, max(0, value))
        applyLinkedLevel(includingBuiltIn: true)
    }

    /// Sends the shared level to the screens: the Mac too, or only the others when the Mac itself moved.
    private func applyLinkedLevel(includingBuiltIn: Bool) {
        let nits = NitMatch.nits(atLevel: linkedLevel, top: topNits)
        for item in nitDisplays {
            let setting = NitMatch.setting(forNits: nits, profile: nitProfile(item.display, builtIn: item.builtIn))
            if item.builtIn {
                guard includingBuiltIn else { continue }
                if abs((builtInBrightnessValue ?? -1) - setting.hardware) > 0.2 { setBuiltInBrightnessOnly(setting.hardware) }
                lastMirroredBuiltIn = setting.hardware
            } else if abs((requestedBrightness[item.display.id] ?? -1) - setting.hardware) > 0.2 {
                setExternalBrightness(setting.hardware, of: item.display.id)
            }
            linkDimmer.set(setting.light * 100, for: item.display.id)
        }
        // Screens without hardware brightness keep following the bar in percent.
        for probe in probes where softwareDimmed.contains(probe.display.id) {
            setExternalBrightness(linkedLevel, of: probe.display.id)
        }
    }

    /// The Mac's brightness changed outside PanelLight (keys, auto-brightness): move the bar and the others with it.
    private func followBuiltIn(force: Bool = false) {
        guard linkBrightness else { return }
        guard let display = builtInDisplay, let value = builtInBrightnessValue, canChangeBuiltInBrightness else {
            if force { applyLinkedLevel(includingBuiltIn: true) }
            return
        }
        let profile = nitProfile(display, builtIn: true)
        // At the bottom the Mac cannot show where the bar is (the overlay does the rest); keep the bar.
        if !force && value < 0.5 && linkDimmer.level(for: display.id) < 100 { return }
        linkedLevel = NitMatch.level(forNits: NitMatch.nits(atHardware: value, profile: profile), top: topNits)
        linkDimmer.set(100, for: display.id)
        applyLinkedLevel(includingBuiltIn: false)
    }

    func setKeyboardBrightness(_ value: Double) {
        guard keyboardBrightnessValue != nil else { return }
        let requested = min(100, max(0, value))
        keyboardBrightnessValue = requested
        clearError()
        keyboardRequest += 1
        let request = keyboardRequest
        keyboardWritePending = true
        keyboardScheduler.schedule(after: 0) { [weak self] in
            guard let self, self.keyboardRequest == request else { return }
            var readback: Float = 0
            let target = Float(requested / 100)
            if MBWriteKeyboardBrightness(target), MBReadKeyboardBrightness(&readback) {
                self.keyboardBrightnessValue = Double(readback) * 100
                if abs(Double(readback) - Double(target)) > 0.02 {
                    self.report(String(localized: "Keyboard backlight change was not confirmed"))
                }
            } else {
                self.keyboardBrightnessValue = nil
                self.report(String(localized: "Keyboard backlight is unavailable"), source: .keyboardUnavailable)
            }
            self.keyboardWritePending = false
        }
    }

    func setNightShiftWarm(_ warm: Bool) {
        guard nightShiftWarm != nil else { return }
        var active = false, enabled = false
        var mode: Int32 = 0
        guard MBReadNightShift(&active, &enabled, &mode) else { return }
        if warm { nightShiftEnabledBeforeOverride = enabled }
        let enabledWhenOff = nightShiftEnabledBeforeOverride ?? (mode != 0 && enabled)
        if !MBSetNightShiftWarm(warm, enabledWhenOff) {
            report(String(localized: "Night Shift change was not confirmed"))
        } else {
            clearError()
            if !warm { nightShiftEnabledBeforeOverride = nil }
        }
        pollNightShift()
    }

    private func setExternalBrightness(_ value: Double, of id: UInt32) {
        guard let probe = probes.first(where: { $0.display.id == id }) else { return }
        requestedBrightness[id] = min(100, max(0, value))
        if softwareDimmed.contains(id) {
            dimmer.set(value, for: id)
            replaceLevels(softwareLevels(id), vcp: 0x10, displayID: id)
            return
        }
        guard let levels = probe.brightness,
              let raw = rawLevel(percent: value, maximum: levels.maximum) else { return }
        // Show the requested level right away; the monitor's readback replaces it once the write lands.
        replaceLevels(HardwareLevels(current: raw, maximum: levels.maximum), vcp: 0x10, displayID: id)
        clearError()
        let request = (brightnessRequests[id] ?? 0) + 1
        brightnessRequests[id] = request
        let token = generation
        let queue = brightnessQueues[id] ?? LatestWriteQueue()
        brightnessQueues[id] = queue
        queue.submit { [weak self] finish in
            guard let self else { finish(); return }
            self.send(display: probe.display, vcp: 0x10, raw: raw, token: token,
                      request: request, finished: finish)
        }
    }

    private func setBuiltInBrightnessOnly(_ value: Double) {
        guard let display = builtInDisplay, builtInBrightnessValue != nil else { return }
        let requested = min(100, max(0, value))
        builtInBrightnessValue = requested
        builtInWritePending = true
        builtInRequest += 1
        let request = builtInRequest
        builtInScheduler.schedule(after: 0) { [weak self] in
            guard let self, self.builtInDisplay?.id == display.id, self.builtInRequest == request else { return }
            let target = Float(requested / 100)
            var readback: Float = 0
            if MBWriteBuiltInBrightness(display.id, target), MBReadBuiltInBrightness(display.id, &readback) {
                self.builtInBrightnessValue = Double(readback) * 100
                self.lastMirroredBuiltIn = Double(readback) * 100
                if abs(Double(readback) - Double(target)) > 0.02 {
                    self.report(String(localized: "Built-in display change was not confirmed"))
                }
            } else {
                self.builtInBrightnessValue = nil
                self.report(String(localized: "Built-in display brightness is unavailable"), source: .builtInUnavailable)
            }
            self.builtInWritePending = false
        }
    }

    // One contrast control for every screen that supports it: monitors over DDC/CI, the Mac and monitors that
    // keep DDC/CI contrast fixed via gamma.
    func setContrast(_ value: Double) {
        let hardware = probes.compactMap { probe -> (DisplayIdentity, UInt16)? in
            guard !contrastLocked.contains(probe.display.id), let levels = probe.contrast,
                  let raw = rawLevel(percent: value, maximum: levels.maximum) else { return nil }
            return (probe.display, raw)
        }
        let software = probes.filter { contrastLocked.contains($0.display.id) }.map(\.display)
        guard !hardware.isEmpty || !software.isEmpty else { return }
        contrastValue = value
        clearError()
        contrastRequest += 1
        let token = generation
        let request = contrastRequest
        contrastScheduler.schedule(after: 0.15) { [weak self] in
            guard let self, self.generation == token else { return }
            self.builtInContrastFailed = self.builtInDisplay.map {
                !self.gamma.apply(value, to: $0.id)
            } ?? false
            for display in software where self.contrastLocked.contains(display.id) {
                self.setGammaContrast(value, on: display)
            }
            for (display, raw) in hardware {
                // One write at a time per monitor; slider moves made meanwhile collapse into the newest.
                let queue = self.contrastQueues[display.id] ?? LatestWriteQueue()
                self.contrastQueues[display.id] = queue
                queue.submit { [weak self] finish in
                    guard let self else { finish(); return }
                    // The monitor turned out to lock contrast while this move waited: gamma already has it.
                    guard !self.contrastLocked.contains(display.id) else { finish(); return }
                    self.send(display: display, vcp: 0x12, raw: raw, token: token, request: request, finished: finish)
                }
            }
        }
    }

    private func setGammaContrast(_ value: Double, on display: DisplayIdentity) {
        if !gamma.apply(value, to: display.id) {
            report(String(localized: "\(display.name) contrast could not be applied"), source: .display)
        }
        replaceLevels(gammaLevels(value), vcp: 0x12, displayID: display.id, resync: false)
    }

    private func gammaLevels(_ value: Double) -> HardwareLevels {
        HardwareLevels(current: UInt16((min(100, max(0, value)) * 10).rounded()), maximum: 1000)
    }

    private func updateDisplays(_ newDisplays: [DisplayIdentity], force: Bool) {
        dimmer.keep(only: softwareDimmed.intersection(newDisplays.map(\.id)))
        linkDimmer.keep(only: Set(newDisplays.map(\.id)).union([DisplayDiscovery.builtInDisplay()?.id].compactMap { $0 }))
        let nextBuiltInDisplay = DisplayDiscovery.builtInDisplay()
        if !force && newDisplays == displays && nextBuiltInDisplay?.id == builtInDisplay?.id &&
            (!probes.isEmpty || isProbing) {
            return
        }
        generation += 1
        cancelPendingWrites()
        contrastScheduler.cancel()
        builtInScheduler.cancel()
        builtInWritePending = false
        if let old = builtInDisplay, nextBuiltInDisplay?.id != old.id { gamma.restore(old.id) }
        builtInDisplay = nextBuiltInDisplay
        // What was learned about a monitor ends with its connection; plugged in again, it is tried afresh.
        let connected = Set(newDisplays.map(\.id))
        for id in contrastLocked.subtracting(connected) { gamma.restore(id) }
        if !contrastLocked.isSubset(of: connected) { contrastLocked.formIntersection(connected) }
        if !brightnessLocked.isSubset(of: connected) { brightnessLocked.formIntersection(connected) }
        ignoredBrightnessWrites = ignoredBrightnessWrites.filter { connected.contains($0.key) }
        requestedBrightness = requestedBrightness.filter { connected.contains($0.key) }
        if let builtInDisplay {
            var level: Float = 0
            builtInBrightnessValue = MBReadBuiltInBrightness(builtInDisplay.id, &level) ? Double(level) * 100 : nil
            lastMirroredBuiltIn = builtInBrightnessValue
        } else {
            builtInBrightnessValue = nil
            lastMirroredBuiltIn = nil
        }
        displays = newDisplays
        if newDisplays.isEmpty {
            probes = []
            softwareDimmed = []
            isProbing = false
            updatePolling()
            return
        }
        probe(newDisplays, token: generation)
    }

    private func probe(_ displays: [DisplayIdentity], token: Int) {
        isProbing = true
        let requestsAtStart = brightnessRequests
        let contrastRequestAtStart = contrastRequest
        // Displays not yet known to lack DDC/CI get a few more tries before they fall back to software dimming.
        let patient = Set(displays.map(\.id)).subtracting(softwareDimmed)
        DDCClient.shared.probe(displays: displays.filter { !$0.isVirtual }, patient: patient) { [weak self] results in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                var dimmed = Set<UInt32>()
                let contrastMoved = self.contrastRequest != contrastRequestAtStart
                self.probes = displays.map { display in
                    let result = results.first { $0.display.id == display.id }
                    // A slider moved during the probe: keep its newer value instead of the reading taken before it.
                    let current = self.probes.first { $0.display.id == display.id }
                    let gammaContrast = self.contrastLocked.contains(display.id)
                        ? current?.contrast ?? self.gammaLevels(50) : nil
                    let hardwareContrast = contrastMoved ? current?.contrast ?? result?.contrast : result?.contrast
                    if let result, result.brightness != nil, !self.brightnessLocked.contains(display.id) {
                        let brightnessMoved = self.brightnessRequests[display.id] != requestsAtStart[display.id]
                        return DDCProbe(display: display,
                                        brightness: brightnessMoved ? current?.brightness ?? result.brightness : result.brightness,
                                        contrast: gammaContrast ?? hardwareContrast,
                                        input: result.input, issue: result.issue)
                    }
                    dimmed.insert(display.id)
                    // A monitor with locked brightness still answers DDC/CI, so its contrast keeps working.
                    let answers = self.brightnessLocked.contains(display.id)
                    return DDCProbe(display: display, brightness: self.softwareLevels(display.id),
                                    contrast: gammaContrast ?? (answers ? hardwareContrast : nil),
                                    input: result?.input, issue: result?.issue)
                }
                // A wake or a mode change can reset the gamma table; put the software contrast back.
                for probe in self.probes where self.contrastLocked.contains(probe.display.id) {
                    if let percent = probe.contrast?.percent { _ = self.gamma.apply(percent, to: probe.display.id) }
                }
                self.softwareDimmed = dimmed
                self.dimmer.keep(only: dimmed)
                self.isProbing = false
                self.clearError(from: .display)
                self.syncContrast()
                self.syncExternalToBuiltIn()
                self.updatePolling()
            }
        }
    }

    private func softwareLevels(_ id: UInt32) -> HardwareLevels {
        HardwareLevels(current: UInt16((dimmer.level(for: id) * 10).rounded()), maximum: 1000)
    }

    private func cancelPendingWrites() {
        brightnessQueues.values.forEach { $0.cancel() }
        contrastQueues.values.forEach { $0.cancel() }
    }

    private func send(display: DisplayIdentity, vcp: UInt8, raw: UInt16, token: Int,
                      request: Int, finished: (@MainActor () -> Void)? = nil) {
        guard generation == token else { finished?(); return }
        DDCClient.shared.write(display: display, vcp: vcp, raw: raw) { [weak self] result in
            Task { @MainActor in
                defer { finished?() }
                guard let self, self.generation == token else { return }
                // Every answer teaches whether the control is locked, even one a newer slider move overtook.
                self.learn(from: result, vcp: vcp, display: display)
                // Moved to software (now or while this write ran): the monitor's own level no longer counts.
                guard !(vcp == 0x10 ? self.brightnessLocked : self.contrastLocked).contains(display.id),
                      request == (vcp == 0x10 ? self.brightnessRequests[display.id] : self.contrastRequest)
                else { return }
                switch result {
                case .applied(let levels), .adjusted(let levels):
                    // A monitor that rounds or clamps the level is not an error: the slider shows where it landed.
                    self.replaceLevels(levels, vcp: vcp, displayID: display.id)
                    if vcp == 0x12 && self.builtInContrastFailed {
                        self.report(String(localized: "Built-in display contrast could not be applied"))
                    } else {
                        self.clearError()
                    }
                case .ignored(let levels):
                    // One ignored brightness write is not a lock yet (a monitor still waking up misses some):
                    // show the level it really has.
                    self.replaceLevels(levels, vcp: vcp, displayID: display.id)
                case .unreadable:
                    self.report(String(localized: "\(display.name) did not confirm the change"), source: .display)
                    // The write already retried; look again at what the monitor can do, once at a time.
                    if !self.isProbing { self.probe(self.displays, token: token) }
                }
            }
        }
    }

    // A control the monitor ignores twice in a row (brightness) or once (contrast, which many monitors lock
    // outside their standard picture mode) moves to software, so the slider keeps doing what it shows.
    private func learn(from result: DDCWriteResult, vcp: UInt8, display: DisplayIdentity) {
        let id = display.id
        switch result {
        case .applied, .adjusted:
            if vcp == 0x10 { ignoredBrightnessWrites[id] = nil }
            return
        case .unreadable:
            return
        case .ignored:
            break
        }
        guard displays.contains(where: { $0.id == id }) else { return }
        if vcp == 0x12 {
            guard !contrastLocked.contains(id) else { return }
            contrastLocked.insert(id)
            contrastQueues[id]?.cancel()
            setGammaContrast(contrastValue, on: display)
            return
        }
        guard !brightnessLocked.contains(id) else { return }
        let ignored = (ignoredBrightnessWrites[id] ?? 0) + 1
        ignoredBrightnessWrites[id] = ignored
        guard ignored >= 2 else { return }
        brightnessLocked.insert(id)
        brightnessQueues[id]?.cancel()
        softwareDimmed.insert(id)
        dimmer.set(requestedBrightness[id] ?? 100, for: id)
        replaceLevels(softwareLevels(id), vcp: 0x10, displayID: id)
        clearError(from: .display)
    }

    private func replaceLevels(_ levels: HardwareLevels?, vcp: UInt8, displayID: UInt32, resync: Bool = true) {
        guard let levels, let index = probes.firstIndex(where: { $0.display.id == displayID }) else { return }
        let old = probes[index]
        probes[index] = DDCProbe(display: old.display,
                                 brightness: vcp == 0x10 ? levels : old.brightness,
                                 contrast: vcp == 0x12 ? levels : old.contrast,
                                 input: old.input, issue: old.issue)
        if vcp == 0x12 && resync { syncContrast() }
    }

    private func syncContrast() {
        contrastValue = probes.first { $0.contrast != nil }?.contrast?.percent ?? 0
    }

    private func syncExternalToBuiltIn() {
        followBuiltIn(force: true)
    }

    var isPolling: Bool { pollTimer != nil }

    // The panel tells the model when it is on screen. Closed, nothing shown needs fresh readings, so the 1 s timer
    // only runs for Link, which follows the Mac's brightness keys onto the monitors.
    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible { poll() }
        updatePolling()
    }

    private func updatePolling() {
        let needed = pollingNeeded(panelVisible: isPanelVisible, linkOn: linkBrightness, hasBuiltIn: builtInDisplay != nil,
                                   hasLinkedDisplay: probes.contains { $0.brightness != nil })
        if needed && pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.3
            pollTimer = timer
        } else if !needed, let pollTimer {
            pollTimer.invalidate()
            self.pollTimer = nil
        }
    }

    private func poll() {
        if isPanelVisible {
            pollKeyboardBrightness()
            pollNightShift()
        }
        pollBuiltInBrightness()
    }

    private func pollBuiltInBrightness() {
        guard !builtInWritePending else { return }
        guard let display = builtInDisplay else { return }
        var raw: Float = 0
        guard MBReadBuiltInBrightness(display.id, &raw) else { return }
        receivePolledBuiltInBrightness(Double(raw) * 100)
    }

    // The poll can run while the panel is closed (Link). Publishing an unchanged reading still fires
    // objectWillChange and re-lays out the hidden panel every tick, so only real changes are published.
    func receivePolledBuiltInBrightness(_ value: Double) {
        if builtInBrightnessValue != value { builtInBrightnessValue = value }
        clearError(from: .builtInUnavailable)
        guard let previous = lastMirroredBuiltIn else {
            lastMirroredBuiltIn = value
            return
        }
        if !linkBrightness {
            lastMirroredBuiltIn = value
        } else if abs(value - previous) >= 2 {
            lastMirroredBuiltIn = value
            followBuiltIn()
        }
    }

    private func pollKeyboardBrightness() {
        guard !keyboardWritePending else { return }
        var raw: Float = 0
        receivePolledKeyboardBrightness(MBReadKeyboardBrightness(&raw) ? Double(raw) * 100 : nil)
    }

    func receivePolledKeyboardBrightness(_ value: Double?) {
        if keyboardBrightnessValue != value { keyboardBrightnessValue = value }
        if value != nil { clearError(from: .keyboardUnavailable) }
    }

    private func pollNightShift() {
        var active = false, enabled = false
        var mode: Int32 = 0
        receivePolledNightShift(MBReadNightShift(&active, &enabled, &mode) ? active && enabled : nil)
    }

    func receivePolledNightShift(_ warm: Bool?) {
        if nightShiftWarm != warm { nightShiftWarm = warm }
    }
}

// Link follows the built-in display onto every external screen (monitors and software-dimmed ones alike),
// so it needs readings while the panel is closed. Nothing else does.
func pollingNeeded(panelVisible: Bool, linkOn: Bool, hasBuiltIn: Bool, hasLinkedDisplay: Bool) -> Bool {
    panelVisible || (linkOn && hasBuiltIn && hasLinkedDisplay)
}
