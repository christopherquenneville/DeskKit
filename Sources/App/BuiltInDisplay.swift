import AppKit
import IOKit

/// On a laptop with monitors connected, keeps the built-in display off while the lid is open: an open
/// lid lets the keyboard side of the case shed heat, which a closed lid traps, without the laptop's
/// screen as one more display. macOS has no public switch for this; DeskKit uses the window server's
/// private call that BetterDisplay and Lunar use. A display turned off that way stays off until it's
/// turned back on or the user logs out, even without DeskKit, so DeskKit is careful to turn it back on:
/// whenever the lid is open and no monitor is on, when the setting is turned off, and when it quits.
@MainActor
final class BuiltInDisplay {
    /// Whether this Mac has a lid (and so a built-in display).
    static let isLaptop = lidOpen != nil

    /// Whether the lid is open, or nil on a Mac without one.
    static var lidOpen: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return !state
    }

    enum Action: Equatable {
        case none
        case turnOff(CGDirectDisplayID)
        case turnOn(CGDirectDisplayID)
    }

    /// What to do about the built-in display `builtIn`, which is on or off, given whether it should be
    /// off while a monitor is on, whether the lid is open, whether a monitor is on, and whether DeskKit
    /// is the one that turned it off.
    static func action(wanted: Bool, lidOpen: Bool, builtIn: CGDirectDisplayID?, builtInOn: Bool,
                       monitors: Bool, turnedOffByDeskKit: Bool) -> Action {
        // With the lid closed the screen is dark anyway, and macOS decides.
        guard lidOpen, let builtIn else { return .none }
        if builtInOn {
            return wanted && monitors ? .turnOff(builtIn) : .none
        }
        // Without a monitor the Mac would have no screen at all: always turn it back on, whoever
        // turned it off. With one, only if DeskKit did and shouldn't any more.
        return !monitors || (turnedOffByDeskKit && !wanted) ? .turnOn(builtIn) : .none
    }

    /// Whether a display is a monitor plugged into the Mac: not the built-in one, and not a virtual
    /// display (macOS adds one when no real display is on, and apps can add their own), which reports
    /// no monitor's vendor.
    static func isMonitor(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(display) == 0 && isReal(display)
    }

    static func isReal(_ display: CGDirectDisplayID) -> Bool {
        let vendor = CGDisplayVendorNumber(display)
        return vendor != 0 && vendor != 0xFFFF_FFFF && vendor != 0x756E_6B6E // none, no monitor, unknown ("unkn")
    }

    /// Whether the built-in display should be off while a monitor is connected.
    var wanted = false {
        didSet { if wanted != oldValue { scheduleChecks([0]) } }
    }

    /// The built-in display DeskKit has turned off, kept in the settings for a DeskKit that starts
    /// again. Only cleared once DeskKit has turned it back on.
    private var off: CGDirectDisplayID? {
        didSet {
            if off != oldValue { Settings.shared.builtInDisplayTurnedOff = off }
            updateSafetyCheck()
        }
    }

    /// Checks after a change of displays: right away, then a few more times, since macOS goes through
    /// in-between states (displays that are gone still listed, reading as built in) before it settles.
    private var checks: [Timer] = []
    private var safetyCheck: Timer?
    private var lastChange: CFTimeInterval = 0
    private static let checkDelays: [TimeInterval] = [0.15, 0.6, 1.5, 3]
    /// Turning the screen off waits until the displays have been still this long; turning it on doesn't wait.
    private static let settleTime: CFTimeInterval = 1

    func start() {
        guard Self.isLaptop else { return }
        off = Settings.shared.builtInDisplayTurnedOff
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        lastChange = CACurrentMediaTime()
        scheduleChecks(Self.checkDelays)
    }

    /// Turns the built-in display back on, for when DeskKit quits.
    func restore() {
        checks.forEach { $0.invalidate() }
        checks = []
        safetyCheck?.invalidate()
        safetyCheck = nil
        guard let display = off else { return }
        turnOn(display)
    }

    @objc private func displaysChanged(_ note: Notification) {
        lastChange = CACurrentMediaTime()
        scheduleChecks(Self.checkDelays)
    }

    private func scheduleChecks(_ delays: [TimeInterval]) {
        checks.forEach { $0.invalidate() }
        checks = delays.map { delay in
            let timer = Timer(timeInterval: delay, target: self, selector: #selector(update(_:)), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    private func scheduleUpdate(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(update(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        checks.append(timer)
    }

    /// While DeskKit has the screen off, it checks again every 10 seconds whether it should still be,
    /// in case a change of displays went unannounced.
    private func updateSafetyCheck() {
        if off != nil, safetyCheck == nil {
            let timer = Timer(timeInterval: 10, target: self, selector: #selector(update(_:)), userInfo: nil, repeats: true)
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            safetyCheck = timer
        } else if off == nil, let timer = safetyCheck {
            timer.invalidate()
            safetyCheck = nil
        }
    }

    @objc private func update(_ timer: Timer) {
        checks.removeAll { $0 === timer }
        let active = Self.activeDisplays()
        guard let lidOpen = Self.lidOpen, let builtIn = builtInDisplay(active: active) else { return }
        let monitors = active.filter(Self.isMonitor)
        // From the list of displays that are on, which never holds one that's gone or off (asked one
        // by one, displays that no longer exist read as on).
        let builtInOn = active.contains(builtIn)
        let settled = CACurrentMediaTime() - lastChange >= Self.settleTime
        // Off with a monitor on is what the setting wants: whoever did it, DeskKit looks after it now.
        // On again, by whatever means, there's nothing to remember.
        if off == nil, settled, wanted, lidOpen, !builtInOn, !monitors.isEmpty { off = builtIn }
        if off != nil, settled, builtInOn { off = nil }
        switch Self.action(wanted: wanted, lidOpen: lidOpen, builtIn: builtIn, builtInOn: builtInOn,
                           monitors: !monitors.isEmpty, turnedOffByDeskKit: off != nil) {
        case .none:
            break
        case .turnOff(let display):
            // Only once the displays have settled; a later check does it.
            guard settled else { return }
            if Self.setEnabled(display, false) {
                off = display
                appLog.info("Turned the built-in display (\(display, privacy: .public)) off, with monitors \(monitors.map { String($0) }.joined(separator: ", "), privacy: .public) on")
            } else {
                appLog.error("Couldn't turn the built-in display (\(display, privacy: .public)) off")
            }
        case .turnOn(let display):
            appLog.info("Turning the built-in display (\(display, privacy: .public)) back on: \(monitors.isEmpty ? "no monitor is on" : "the setting is off", privacy: .public)")
            turnOn(display)
        }
    }

    private func turnOn(_ display: CGDirectDisplayID) {
        // macOS refuses to turn on a display that's already on.
        if Self.activeDisplays().contains(display) {
            off = nil
            return
        }
        if Self.setEnabled(display, true) {
            off = nil
            appLog.info("Turned the built-in display (\(display, privacy: .public)) back on")
        } else {
            // Keep it remembered and try again shortly.
            appLog.error("Couldn't turn the built-in display (\(display, privacy: .public)) back on; trying again")
            scheduleUpdate(after: 1)
        }
    }

    /// The built-in display's number: the one DeskKit turned off (taken as it is, since a display can
    /// read as anything while macOS changes displays), the one that's on, or the one macOS numbers 1.
    /// (Numbers that don't exist read as built in, but without a real vendor.)
    private func builtInDisplay(active: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if let off { return off }
        if let display = active.first(where: { CGDisplayIsBuiltin($0) != 0 && Self.isReal($0) }) { return display }
        return CGDisplayIsBuiltin(1) != 0 && Self.isReal(1) ? 1 : nil
    }

    // MARK: Displays

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private static let configureEnabled: ConfigureEnabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }()

    private static func setEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configureEnabled(config, display, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // Until logout at most. (Even "for this app only", it outlasts DeskKit: see `restore`.)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
