import AppKit
import ApplicationServices

/// One window of an app, as the picker shows it.
struct AppWindow {
    /// The window server's id, for previews (nil if it couldn't be found).
    var id: CGWindowID?
    /// The Accessibility element, for raising and closing it. Accessibility doesn't list windows on
    /// other Spaces: theirs is nil until it's been searched for (see `WindowList.findOnOtherSpaces`).
    var element: AXUIElement?
    var title: String
    /// In CoreGraphics coordinates.
    var frame: CGRect
    var isMinimized: Bool
    var isOnAnotherSpace = false
    /// On another Space, a full-screen app's.
    var isFullScreen = false
}

@MainActor
enum WindowList {
    /// The app's ordinary windows: those on the current Spaces and minimized ones (from Accessibility,
    /// front to back), then any on other Spaces (from the window server; their titles need Screen
    /// Recording, and untitled ones are left out).
    static func windows(of pid: pid_t) -> [AppWindow] {
        var result: [AppWindow] = []
        var known = Set<CGWindowID>()
        for element in AX.windows(of: pid) where AX.isStandardWindow(element) {
            guard let frame = AX.frame(of: element), frame.width >= 60, frame.height >= 40 else { continue }
            let id = AX.windowID(of: element)
            if let id { known.insert(id) }
            result.append(AppWindow(id: id, element: element, title: AX.string(element, kAXTitleAttribute) ?? "",
                                    frame: frame, isMinimized: AX.bool(element, kAXMinimizedAttribute)))
        }
        return result + windowsOnOtherSpaces(of: pid, excluding: known)
    }

    private static func windowsOnOtherSpaces(of pid: pid_t, excluding known: Set<CGWindowID>) -> [AppWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [AppWindow] = []
        var fullScreenSpaces: Set<UInt64>?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !known.contains(id),
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 120, rect.height >= 80 else { continue }
            let spaces = Spaces.spaces(of: id)
            guard !spaces.isEmpty else { continue }
            if fullScreenSpaces == nil { fullScreenSpaces = Spaces.fullScreenSpaces() }
            result.append(AppWindow(id: id, element: nil, title: title, frame: rect, isMinimized: false, isOnAnotherSpace: true,
                                    isFullScreen: !spaces.isDisjoint(with: fullScreenSpaces ?? [])))
        }
        return result
    }

    /// Searches for the elements of windows on other Spaces in the background, as that can take a
    /// moment (see `AX.windowsOnOtherSpaces`), then hands them to `found` on the main actor.
    static func findOnOtherSpaces(_ ids: Set<CGWindowID>, of pid: pid_t,
                                  found: @escaping @MainActor ([CGWindowID: AXUIElement]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CACurrentMediaTime()
            let elements = Elements(byWindow: AX.windowsOnOtherSpaces(ids, of: pid, within: 1))
            let time = Int((CACurrentMediaTime() - start) * 1000)
            appLog.info("Found \(elements.byWindow.count, privacy: .public) of \(ids.count, privacy: .public) windows of \(pid, privacy: .public) on other Spaces in \(time, privacy: .public) ms")
            Task { @MainActor in found(elements.byWindow) }
        }
    }

    /// Whether a window is still open: closing one can take a moment, or wait for an answer.
    static func isOpen(_ window: AppWindow, of pid: pid_t) -> Bool {
        guard let element = window.element else { return false }
        guard window.isOnAnotherSpace else { return AX.windows(of: pid).contains { CFEqual($0, element) } }
        // Accessibility doesn't list it: it's open while the window server has it on a Space.
        return window.id.map { !Spaces.spaces(of: $0).isEmpty } ?? false
    }

    /// Brings a window forward: un-minimizes it and brings it to the front on its own, as clicking it
    /// does, rather than every window of its app. A window on another Space is raised by its app, which
    /// has macOS switch there; this returns false for one, as it only becomes the key window once macOS
    /// has switched (see `raiseOnceReachable`).
    @discardableResult
    static func raise(_ window: AppWindow, of app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if app.isHidden { app.unhide() }
        var element = window.element
        if element == nil, window.isOnAnotherSpace, let id = window.id {
            element = AX.windowsOnOtherSpaces([id], of: pid, within: 0.3)[id]
        }
        if window.isOnAnotherSpace {
            appLog.info("Bringing window \(window.id ?? 0, privacy: .public) of \(pid, privacy: .public) from another Space (element found: \(element != nil, privacy: .public))")
        }
        if let element, window.isMinimized { AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse) }
        if let id = window.id, WindowFocus.focus(id, of: pid) {
            if let element { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
            return !window.isOnAnotherSpace
        }
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        }
        // Accessibility can make another app frontmost even though DeskKit itself isn't active, though
        // that brings all its windows forward.
        if !AX.set(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, kCFBooleanTrue), let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return !window.isOnAnotherSpace
    }

    /// After activating an app whose window is on another Space, raises that window once it's on the
    /// current Space. Returns whether it was found.
    @discardableResult
    static func raiseOnceReachable(_ id: CGWindowID, of app: NSRunningApplication) -> Bool {
        guard let element = AX.windows(of: app.processIdentifier).first(where: { AX.windowID(of: $0) == id }) else {
            return false
        }
        if !WindowFocus.focus(id, of: app.processIdentifier) { AX.set(element, kAXMainAttribute, kCFBooleanTrue) }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return true
    }
}

/// Accessibility elements, to hand from one thread to another: they can be used on any thread.
private struct Elements: @unchecked Sendable {
    let byWindow: [CGWindowID: AXUIElement]
}
