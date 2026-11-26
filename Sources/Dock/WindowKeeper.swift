import AppKit
import ApplicationServices

/// Keeps zoomed, tiled and new windows beside the bars instead of under them, the way the Dock's
/// reserved space does on its own display. macOS has no way for an app to reserve part of a screen,
/// so this moves the windows themselves through the Accessibility API, which needs the user's OK.
///
/// Only windows that were resized (zoomed, filled, tiled) or just opened against a bar's edge are
/// touched; a window the user drags under a bar stays there, as it can under the Dock. A window
/// fitted beside a bar remembers its earlier frame, so zooming it again still restores it.
@MainActor
final class WindowKeeper {
    /// A bar's reserved strip, in CoreGraphics coordinates (origin at the top left of the main display).
    struct Strip {
        let orientation: DockOrientation
        /// The area the bar is attached to: the screen, or beside the Dock on the Dock's own display.
        let edges: CGRect
        /// Where windows go when they fill the screen.
        let visible: CGRect
        /// How far the bar reaches in from its edge.
        let reserve: CGFloat
    }

    private struct Tracked {
        let window: AXUIElement
        var lastFrame: CGRect?
        var fitted: CGRect?
        var fittedAt: CFTimeInterval = 0
        var restore: CGRect?
        var restoredTo: CGRect?
        var restoredAt: CFTimeInterval = 0
        var pending = false
        var resized = false
        /// When the first of the resize reports still waiting to be handled came in, and the latest.
        var resizedAt: CFTimeInterval = 0
        var lastResizedAt: CFTimeInterval = 0
        var created = false
    }

    /// macOS reports a zoom's or tile's final frame as soon as it starts, then animates the window there
    /// for about this long. Moving the window meanwhile fights the animation and makes it jitter.
    private static let animationDuration: CFTimeInterval = 0.4
    /// Some apps (Chrome) report every frame of the animation instead, which can run longer: it's over
    /// once they've been quiet this long.
    private static let quietAfterAnimation: CFTimeInterval = 0.12
    /// Within this window after fitting, a window's reports are macOS still settling it (a full-size
    /// report is the zoom animation finishing), not the user zooming back out.
    private static let animationAllowance: CFTimeInterval = 0.8

    /// The strips of the bars that stay on screen, asked for whenever a window needs checking.
    var strips: () -> [Strip] = { [] }

    private(set) var isActive = false
    private var observers: [pid_t: AXObserver] = [:]
    private var watchRetries: [pid_t: Int] = [:]
    private var tracked: [Tracked] = []
    private var settleTimer: Timer?
    private var recheckTimer: Timer?
    private static let tolerance: CGFloat = 12

    func start(watching apps: [RunningApp]) {
        guard !isActive else { return }
        isActive = true
        apps.forEach { watch($0.pid) }
        appLog.info("Keeping windows clear of the bars")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for pid in Array(observers.keys) { unwatch(pid) }
        tracked.removeAll()
        settleTimer?.invalidate()
        settleTimer = nil
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    func watch(_ pid: pid_t) {
        guard isActive, observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, windowKeeperCallback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXFocusedWindowChangedNotification] {
            let error = AXObserverAddNotification(observer, app, name as CFString, me)
            guard error == .success || error == .notificationAlreadyRegistered else {
                // An app that has only just launched may not answer yet: try again shortly.
                let tries = watchRetries[pid, default: 0]
                appLog.debug("Can't watch the windows of \(pid, privacy: .public) yet (\(error.rawValue, privacy: .public))")
                if tries < 20 {
                    watchRetries[pid] = tries + 1
                    let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(retryWatch(_:)), userInfo: pid, repeats: false)
                    RunLoop.main.add(timer, forMode: .common)
                }
                return
            }
        }
        watchRetries[pid] = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        snapshot(pid)
    }

    @objc private func retryWatch(_ timer: Timer) {
        if let pid = timer.userInfo as? pid_t { watch(pid) }
    }

    /// Notes where an app's windows are now, so one zoomed before it ever moved can still be restored.
    func snapshot(_ pid: pid_t) {
        guard isActive else { return }
        for window in AX.windows(of: pid) {
            guard let frame = frame(of: window) else { continue }
            if let i = tracked.firstIndex(where: { CFEqual($0.window, window) }) {
                if !tracked[i].pending && tracked[i].fitted == nil { tracked[i].lastFrame = frame }
            } else {
                tracked.append(Tracked(window: window, lastFrame: frame))
            }
        }
        if tracked.count > 300 { tracked.removeFirst(tracked.count - 300) }
    }

    func unwatch(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watchRetries[pid] = nil
        tracked.removeAll { AX.pid(of: $0.window) == pid }
    }

    // MARK: Notifications

    fileprivate func noticed(_ window: AXUIElement, _ notification: String) {
        guard isActive else { return }
        appLog.debug("\(notification, privacy: .public) from \(AX.pid(of: window), privacy: .public)")
        let index: Int
        if let found = tracked.firstIndex(where: { CFEqual($0.window, window) }) {
            index = found
        } else {
            if tracked.count > 300 { tracked.removeFirst(tracked.count - 300) }
            tracked.append(Tracked(window: window))
            index = tracked.count - 1
        }
        switch notification {
        case kAXFocusedWindowChangedNotification:
            // Not a change, just a chance to learn the frame to restore after a zoom.
            if !tracked[index].pending { tracked[index].lastFrame = frame(of: window) }
            return
        case kAXWindowResizedNotification:
            let now = CACurrentMediaTime()
            if !tracked[index].resized { tracked[index].resizedAt = now }
            tracked[index].lastResizedAt = now
            tracked[index].resized = true
        case kAXWindowCreatedNotification:
            tracked[index].created = true
        default:
            break
        }
        tracked[index].pending = true
        // The short wait gathers the moved and resized reports that arrive together; a zoom or tile
        // then waits for its animation to finish (see `settle`).
        if settleTimer == nil { scheduleSettle(after: 0.02) }
    }

    private func scheduleSettle(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(settle(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// Checks the windows that changed, once the mouse is up (a window being dragged or resized by hand is left alone).
    @objc private func settle(_ timer: Timer) {
        settleTimer = nil
        if NSEvent.pressedMouseButtons != 0 {
            scheduleSettle(after: 0.05)
            return
        }
        let now = CACurrentMediaTime()
        let strips = strips()
        var gone: [Int] = []
        var nextCheck: TimeInterval?
        for i in tracked.indices where tracked[i].pending {
            let entry = tracked[i]
            // Let a zoom or tile finish animating, then move the window once. (Reports that follow a fit
            // of ours are handled at once, below.)
            let settlingFit = entry.fitted != nil && now - entry.fittedAt < Self.animationAllowance
            let wait = max(Self.animationDuration - (now - entry.resizedAt), Self.quietAfterAnimation - (now - entry.lastResizedAt))
            if entry.resized, !entry.created, !settlingFit, wait > 0 {
                nextCheck = min(nextCheck ?? wait, wait)
                continue
            }
            tracked[i].pending = false
            tracked[i].resized = false
            tracked[i].created = false
            guard let frame = frame(of: entry.window) else {
                gone.append(i)
                continue
            }
            tracked[i].lastFrame = frame
            appLog.debug("Window \(String(describing: frame), privacy: .public) resized \(entry.resized) created \(entry.created), \(strips.count) strips")
            // While its zoom settles, macOS can give a fitted window its new size but leave it where it was
            // for a moment. Put it where it was fitted to: fitting what's left of it again made it narrower
            // each time.
            if let fitted = entry.fitted, now - entry.fittedAt < Self.animationAllowance {
                if !close(frame, fitted) { setFrame(entry.window, fitted) }
                tracked[i].lastFrame = fitted
                continue
            }
            guard entry.resized || entry.created, isOrdinaryWindow(entry.window),
                  let strip = strips.first(where: { touches(frame, $0) }) else {
                if let fitted = entry.fitted, !close(frame, fitted) {
                    tracked[i].fitted = nil
                    tracked[i].restore = nil
                }
                continue
            }
            // The un-zoom animation finished after the restore below and filled the screen again: restore again.
            if let restored = entry.restoredTo, now - entry.restoredAt < Self.animationAllowance, fills(frame, strip) {
                setFrame(entry.window, restored)
                tracked[i].lastFrame = restored
                continue
            }
            let settling = now - entry.fittedAt < Self.animationAllowance
            // Zoomed again after being fitted: the user is un-zooming, so put back the frame from before.
            if !settling, let fitted = entry.fitted, let last = entry.lastFrame, close(last, fitted), fills(frame, strip),
               let restore = entry.restore {
                setFrame(entry.window, restore)
                tracked[i].lastFrame = restore
                tracked[i].fitted = nil
                tracked[i].restore = nil
                tracked[i].restoredTo = restore
                tracked[i].restoredAt = now
                continue
            }
            let target = fit(frame, beside: strip, keepSize: entry.created && !entry.resized)
            appLog.debug("Fitting window beside the bar: \(String(describing: target), privacy: .public)")
            setFrame(entry.window, target)
            if !settling {
                tracked[i].restore = entry.lastFrame.flatMap { touches($0, strip) ? nil : $0 } ?? entry.restore
            }
            tracked[i].fitted = target
            tracked[i].fittedAt = now
            tracked[i].lastFrame = target
            scheduleRecheck()
        }
        for i in gone.reversed() { tracked.remove(at: i) }
        if let nextCheck, settleTimer == nil { scheduleSettle(after: nextCheck) }
    }

    /// A window that took its new size but not yet its place may send no more reports: look again
    /// once the zoom has had time to finish.
    private func scheduleRecheck() {
        recheckTimer?.invalidate()
        let timer = Timer(timeInterval: Self.animationAllowance * 0.6, target: self, selector: #selector(recheck(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    @objc private func recheck(_ timer: Timer) {
        recheckTimer = nil
        let now = CACurrentMediaTime()
        for i in tracked.indices where tracked[i].fitted != nil && now - tracked[i].fittedAt < Self.animationAllowance {
            tracked[i].pending = true
        }
        if settleTimer == nil { scheduleSettle(after: 0) }
    }

    // MARK: Geometry

    /// The window reaches into the strip from the bar's own edge (allowing tiling margins).
    private func touches(_ frame: CGRect, _ strip: Strip) -> Bool {
        let e = strip.edges, r = strip.reserve, t = Self.tolerance
        switch strip.orientation {
        case .left:
            return frame.minX <= e.minX + t && frame.maxX > e.minX + r && frame.maxY > e.minY && frame.minY < e.maxY
        case .right:
            return frame.maxX >= e.maxX - t && frame.minX < e.maxX - r && frame.maxY > e.minY && frame.minY < e.maxY
        case .bottom:
            return frame.maxY >= e.maxY - t && frame.minY < e.maxY - r && frame.maxX > e.minX && frame.minX < e.maxX
        }
    }

    /// The window fills the screen's visible area, as zooming or "Fill" leaves it.
    private func fills(_ frame: CGRect, _ strip: Strip) -> Bool {
        let v = strip.visible, t = Self.tolerance
        return abs(frame.minX - v.minX) <= t && abs(frame.maxX - v.maxX) <= t
            && abs(frame.minY - v.minY) <= t && abs(frame.maxY - v.maxY) <= t
    }

    /// Moves the window's bar-side edge out of the strip, keeping any tiling margin. A resized window
    /// keeps its far edge (so tiles stay put); a new window keeps its size and shifts over instead.
    private func fit(_ frame: CGRect, beside strip: Strip, keepSize: Bool) -> CGRect {
        let e = strip.edges, r = strip.reserve
        var f = frame
        switch strip.orientation {
        case .left:
            let minX = e.minX + r + max(0, frame.minX - e.minX)
            f.size.width = keepSize ? min(frame.width, e.maxX - minX) : frame.maxX - minX
            f.origin.x = minX
        case .right:
            let maxX = e.maxX - r - max(0, e.maxX - frame.maxX)
            if keepSize { f.origin.x = max(e.minX, maxX - frame.width) }
            f.size.width = maxX - f.minX
        case .bottom:
            let maxY = e.maxY - r - max(0, e.maxY - frame.maxY)
            if keepSize { f.origin.y = max(strip.visible.minY, maxY - frame.height) }
            f.size.height = maxY - f.minY
        }
        return f
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    // MARK: Accessibility

    private func frame(of window: AXUIElement) -> CGRect? { AX.frame(of: window) }
    private func setFrame(_ window: AXUIElement, _ rect: CGRect) { AX.setFrame(window, rect) }

    /// Standard windows only: not sheets, panels or dialogs, and not minimized or full screen.
    private func isOrdinaryWindow(_ window: AXUIElement) -> Bool {
        AX.isStandardWindow(window) && !AX.bool(window, kAXMinimizedAttribute) && !AX.bool(window, "AXFullScreen")
    }
}

/// AXObserver's C callback; observers are scheduled on the main run loop.
private func windowKeeperCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                  _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let name = notification as String
    MainActor.assumeIsolated {
        Unmanaged<WindowKeeper>.fromOpaque(refcon).takeUnretainedValue().noticed(element, name)
    }
}
