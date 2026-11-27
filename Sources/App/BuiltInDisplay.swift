import AppKit
import IOKit

/// On a laptop with external displays connected, keeps the built-in display off while the lid is
/// open: an open lid lets the keyboard side of the case shed heat, which a closed lid traps, without
/// the laptop's screen as one more display. macOS has no public switch for this; DeskKit uses the
/// window server's private call that BetterDisplay and Lunar use. The display stays off until it's
/// turned back on or the user logs out, even if DeskKit has quit, so DeskKit turns it back on when it
/// quits and remembers which display it turned off in case it couldn't.
@MainActor
final class BuiltInDisplay {
    /// Whether this Mac has a lid (and so a built-in display).
    static let isLaptop: Bool = {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let lid = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else { return false }
        _ = lid.takeRetainedValue()
        return true
    }()

    enum Action: Equatable {
        case none
        case turnOff(CGDirectDisplayID)
        case turnOn(CGDirectDisplayID)
    }

    /// What to do, given whether the built-in display should be off while external displays are
    /// connected, the active displays (and which of them is built in), and the display DeskKit has off.
    static func action(wanted: Bool, active: [(id: CGDirectDisplayID, builtIn: Bool)], off: CGDirectDisplayID?) -> Action {
        let externals = active.contains { !$0.builtIn }
        if let off {
            return wanted && externals ? .none : .turnOn(off)
        }
        if wanted, externals, let builtIn = active.first(where: \.builtIn) {
            return .turnOff(builtIn.id)
        }
        return .none
    }

    /// Whether the built-in display should be off while external displays are connected.
    var wanted = false {
        didSet { if wanted != oldValue { scheduleUpdate(after: 0) } }
    }

    /// The display DeskKit has turned off, kept in the settings for a DeskKit that starts again.
    private var off: CGDirectDisplayID? {
        didSet { if off != oldValue { Settings.shared.builtInDisplayTurnedOff = off } }
    }

    private var pending: Timer?

    func start() {
        guard Self.isLaptop else { return }
        off = Settings.shared.builtInDisplayTurnedOff
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        scheduleUpdate(after: 0.5)
    }

    /// Turns the built-in display back on, for when DeskKit quits.
    func restore() {
        pending?.invalidate()
        pending = nil
        guard let display = off else { return }
        turnOn(display)
    }

    @objc private func displaysChanged(_ note: Notification) {
        // Displays come and go in steps (a monitor waking, the lid opening): act once they've settled.
        scheduleUpdate(after: 1)
    }

    private func scheduleUpdate(after delay: TimeInterval) {
        pending?.invalidate()
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(update(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        pending = timer
    }

    @objc private func update(_ timer: Timer) {
        pending = nil
        // A display remembered as off may be on again (logging out turns it back on).
        if let display = off, CGDisplayIsActive(display) != 0 { off = nil }
        let active = Self.activeDisplays().map { (id: $0, builtIn: CGDisplayIsBuiltin($0) != 0) }
        switch Self.action(wanted: wanted, active: active, off: off) {
        case .none:
            break
        case .turnOff(let display):
            if Self.setEnabled(display, false) {
                off = display
                appLog.info("Turned the built-in display (\(display, privacy: .public)) off, with \(active.count - 1, privacy: .public) external display(s) on")
            } else {
                appLog.error("Couldn't turn the built-in display off")
            }
        case .turnOn(let display):
            turnOn(display)
        }
    }

    private func turnOn(_ display: CGDirectDisplayID) {
        // If it came back with another number, turn on whichever built-in display is connected but off.
        let candidates = [display] + Self.onlineDisplays().filter { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) == 0 && $0 != display }
        if candidates.contains(where: { Self.setEnabled($0, true) }) {
            appLog.info("Turned the built-in display back on")
        } else {
            appLog.error("Couldn't turn the built-in display back on")
        }
        off = nil
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
        displays(CGGetActiveDisplayList)
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        displays(CGGetOnlineDisplayList)
    }

    private static func displays(_ list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard list(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard list(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
