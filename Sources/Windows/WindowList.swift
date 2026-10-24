import AppKit
import ApplicationServices

/// One window of an app, as the picker shows it.
struct AppWindow {
    /// The window server's id, for previews (nil if it couldn't be found).
    var id: CGWindowID?
    /// The Accessibility element, for raising it. Nil for a window on another Space.
    var element: AXUIElement?
    var title: String
    /// In CoreGraphics coordinates.
    var frame: CGRect
    var isMinimized: Bool

    var isOnAnotherSpace: Bool { element == nil }
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
        var candidates: [AppWindow] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !known.contains(id),
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 120, rect.height >= 80 else { continue }
            candidates.append(AppWindow(id: id, element: nil, title: title, frame: rect, isMinimized: false))
        }
        let onSpaces = Spaces.windowsOnSomeSpace(candidates.compactMap(\.id))
        return candidates.filter { $0.id.map(onSpaces.contains) ?? false }
    }

    /// Brings a window forward: un-minimizes and raises it, then makes its app frontmost.
    /// Returns false for a window on another Space, which can only be raised once macOS has
    /// switched there (see `raiseOnceReachable`).
    @discardableResult
    static func raise(_ window: AppWindow, of app: NSRunningApplication) -> Bool {
        if app.isHidden { app.unhide() }
        if let element = window.element {
            if window.isMinimized { AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse) }
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        }
        // Accessibility can make another app frontmost even though DeskKit itself isn't active.
        if !AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue),
           let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return window.element != nil
    }

    /// After activating an app whose window is on another Space, raises that window once it's on the
    /// current Space. Returns whether it was found.
    @discardableResult
    static func raiseOnceReachable(_ id: CGWindowID, of app: NSRunningApplication) -> Bool {
        guard let element = AX.windows(of: app.processIdentifier).first(where: { AX.windowID(of: $0) == id }) else {
            return false
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        return true
    }
}
