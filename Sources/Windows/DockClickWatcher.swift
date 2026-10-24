import AppKit
import ApplicationServices

/// Catches plain clicks on a running app's icon in the real Dock, so DeskKit can show the window
/// picker instead of the Dock activating the app. Only clicks on apps with two or more windows are
/// held back; a click with a modifier key, on anything else, or that turns into a drag or a press
/// and hold, reaches the Dock as usual. Needs Accessibility access.
@MainActor
final class DockClickWatcher: NSObject {
    /// Asked for a click on a running app's Dock icon, with the app's windows, the icon's frame in
    /// screen coordinates and the Dock's edge. Returns whether it handled the click.
    var onClick: ((NSRunningApplication, [AppWindow], NSRect, DockOrientation) -> Bool)?

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held: Held?
    private var holdTimer: Timer?
    private var geometry: (orientation: DockOrientation, reach: CGFloat) = (.bottom, 0)
    private var geometryReadAt: CFTimeInterval = -.infinity

    private struct Held {
        let down: CGEvent
        let app: NSRunningApplication
        let windows: [AppWindow]
        let frame: CGRect
        let orientation: DockOrientation
    }

    /// Marks the events DeskKit posts itself when it hands a held click back to the Dock.
    fileprivate static let replayMarker: Int64 = 0x0DE5_C11C
    /// Holding the button longer than this is a press and hold, which shows the Dock's menu for the app.
    private static let pressAndHold: TimeInterval = 0.4

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: dockClickCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        appLog.info("Watching clicks on the Dock")
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        release()
        isRunning = false
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns the event to let it through, or nil to hold it back.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return event }
        switch type {
        case .leftMouseDown:
            release()
            guard event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
                  let item = dockItem(at: event.location) else { return event }
            let windows = WindowList.windows(of: item.app.processIdentifier)
            guard windows.count >= 2 else { return event }
            held = Held(down: event.copy() ?? event, app: item.app, windows: windows, frame: item.frame,
                        orientation: item.orientation)
            let timer = Timer(timeInterval: Self.pressAndHold, target: self, selector: #selector(heldDown(_:)),
                              userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            return nil
        case .leftMouseDragged:
            guard let held else { return event }
            let start = held.down.location, now = event.location
            guard hypot(now.x - start.x, now.y - start.y) > 4 else { return nil }
            // It's a drag (to rearrange or remove the icon): give the Dock the press, then this move.
            release()
            replay(held.down)
            replay(event)
            return nil
        case .leftMouseUp:
            guard let held else { return event }
            release()
            if let onClick, onClick(held.app, held.windows, screenRect(held.frame), held.orientation) { return nil }
            replay(held.down)
            replay(event)
            return nil
        default:
            return event
        }
    }

    /// Still pressed: a press and hold, so the Dock gets the press after all (and shows its menu).
    @objc private func heldDown(_ timer: Timer) {
        guard let held else { return }
        release()
        replay(held.down)
    }

    private func release() {
        held = nil
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func replay(_ event: CGEvent) {
        guard let copy = event.copy() else { return }
        copy.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        copy.post(tap: .cgSessionEventTap)
    }

    /// The running app whose Dock icon is at `point` (CoreGraphics coordinates), if there is one.
    private func dockItem(at point: CGPoint) -> (app: NSRunningApplication, frame: CGRect, orientation: DockOrientation)? {
        let (orientation, reach) = dockGeometry()
        guard nearDockEdge(point, orientation: orientation, reach: reach),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              var element = AX.element(at: point), AX.pid(of: element) == dock.processIdentifier else { return nil }
        // The hit may be part of the icon; walk up to the Dock item itself.
        for _ in 0..<3 where AX.string(element, kAXRoleAttribute) != "AXDockItem" {
            guard let parent = AX.attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return nil
            }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        guard AX.string(element, kAXRoleAttribute) == "AXDockItem",
              AX.string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
              AX.bool(element, "AXIsApplicationRunning"),
              let url = AX.attribute(element, kAXURLAttribute) as? URL, let frame = AX.frame(of: element) else { return nil }
        // Look the app up by bundle id: walking every running app costs a round trip to LaunchServices each.
        let app: NSRunningApplication?
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        } else {
            let path = normalizedPath(url)
            app = NSWorkspace.shared.runningApplications.first { $0.bundleURL.map(normalizedPath) == path }
        }
        guard let app else { return nil }
        return (app, frame, orientation)
    }

    /// The Dock's edge and how far in its icons can reach, re-read at most every 2 s: every click
    /// anywhere asks, and reading the Dock's preferences isn't free.
    private func dockGeometry() -> (orientation: DockOrientation, reach: CGFloat) {
        let now = CACurrentMediaTime()
        if now - geometryReadAt > 2 {
            let prefs = DockPrefs.read()
            geometry = (prefs.orientation, (prefs.magnification ? max(prefs.largeSize, prefs.tileSize) : prefs.tileSize) + 40)
            geometryReadAt = now
        }
        return geometry
    }

    /// A cheap first check: is the point within reach of the Dock's edge on some display?
    private func nearDockEdge(_ point: CGPoint, orientation: DockOrientation, reach: CGFloat) -> Bool {
        for screen in NSScreen.screens {
            let f = screen.frame.inCGCoordinates
            guard f.contains(point) else { continue }
            switch orientation {
            case .bottom: return point.y >= f.maxY - reach
            case .left: return point.x <= f.minX + reach
            case .right: return point.x >= f.maxX - reach
            }
        }
        return false
    }

    /// CoreGraphics coordinates (origin top left of the main display) to AppKit screen coordinates.
    private func screenRect(_ rect: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

private func dockClickCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                               _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return MainActor.assumeIsolated {
        let watcher = Unmanaged<DockClickWatcher>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            watcher.reenable()
            return Unmanaged.passUnretained(event)
        }
        return watcher.handle(type, event).map { Unmanaged.passUnretained($0) }
    }
}
