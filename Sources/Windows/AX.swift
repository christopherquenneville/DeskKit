import AppKit
import ApplicationServices

/// Small helpers over the Accessibility C API, shared by the window picker and the window keeper.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        attribute(element, name) as? Bool ?? false
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    /// A window's frame in CoreGraphics coordinates (origin at the top left of the main display).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func setFrame(_ element: AXUIElement, _ rect: CGRect) {
        // Size, then position, then size again: some apps limit a size that doesn't fit where the window is.
        var size = rect.size, origin = rect.origin
        if let value = AXValueCreate(.cgSize, &size) { set(element, kAXSizeAttribute, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { set(element, kAXPositionAttribute, value) }
        if let value = AXValueCreate(.cgSize, &size) { set(element, kAXSizeAttribute, value) }
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// Standard windows only: not sheets, panels, dialogs or palettes.
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// The element under a point, in CoreGraphics coordinates.
    static func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        return status == .success ? element : nil
    }

    /// The window server's id for a window element. `_AXUIElementGetWindow` is private but has been
    /// stable for many years; it's looked up at run time, and without it previews just aren't matched.
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let getWindow = getWindowFunction else { return nil }
        var id: CGWindowID = 0
        return getWindow(window, &id) == .success && id != 0 ? id : nil
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFunction: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
}

/// Which windows belong to a Space, from the window server's private Spaces API (used the same way
/// by yabai and AltTab). Inactive tabs are windows that belong to no Space.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopySpacesForWindows)? = {
        let all = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(all, "CGSMainConnectionID"), let copy = dlsym(all, "CGSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(copy, to: CopySpacesForWindows.self))
    }()

    /// The windows among `ids` that are on some Space (any Space, current or not).
    static func windowsOnSomeSpace(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard let (mainConnection, copySpaces) = functions else { return [] }
        let connection = mainConnection()
        var result = Set<CGWindowID>()
        for id in ids {
            let spaces = copySpaces(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
            if !spaces.isEmpty { result.insert(id) }
        }
        return result
    }
}
