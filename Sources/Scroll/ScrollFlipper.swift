import AppKit

/// Keeps natural scrolling for trackpads (and Magic Mouse) but makes notched mouse wheels scroll the
/// other way. Trackpads send "continuous" scroll events and wheels don't, so only those are flipped.
@MainActor
final class ScrollFlipper: NSObject {
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?

    /// Starts flipping. Returns false while DeskKit lacks Accessibility access (the tap can't be made).
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        guard install() else { return false }
        isRunning = true
        // Taps can go quiet across sleep, screen lock and user switching without saying so.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(rebuild(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(rebuild(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(rebuild(_:)),
                                                            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        appLog.info("Reversing mouse wheels")
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        uninstall()
    }

    private func install() -> Bool {
        uninstall()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: scrollFlipperCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    /// macOS turned the tap off (it took too long, or secure input): turn it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    @objc private func check(_ timer: Timer) {
        guard let tap, CFMachPortIsValid(tap) else {
            if !install() { appLog.error("Lost the scroll tap and couldn't make a new one") }
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    @objc private func rebuild(_ note: Notification) {
        if isRunning { _ = install() }
    }

    /// Reverses a wheel event. Every delta field is read first, since setting one can recompute the others.
    nonisolated static func flip(_ event: CGEvent) {
        let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -line2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point2)
    }

    nonisolated static func isMouseWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
    }
}

/// Runs for every scroll event, on the main run loop, so it does as little as possible.
private func scrollFlipperCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                   _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .scrollWheel where ScrollFlipper.isMouseWheel(event):
        ScrollFlipper.flip(event)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let refcon {
            MainActor.assumeIsolated { Unmanaged<ScrollFlipper>.fromOpaque(refcon).takeUnretainedValue().reenable() }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
