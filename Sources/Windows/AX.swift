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

    /// Whether the private Spaces API is there to ask; `windowsOnSomeSpace` finds nothing without it.
    static var available: Bool { functions != nil }

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

    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(symbol, to: CopyManagedDisplaySpaces.self)
    }()

    /// The displays showing a full-screen app's Space right now (type 4), by UUID, or "Main" when
    /// displays don't have separate Spaces. Empty if the private API is gone.
    static func fullScreenDisplays() -> Set<String> {
        guard let (mainConnection, _) = functions, let copy = copyManagedDisplaySpaces,
              let displays = copy(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result = Set<String>()
        for display in displays {
            guard let id = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  (current["type"] as? NSNumber)?.intValue == 4 else { continue }
            result.insert(id)
        }
        return result
    }
}

/// Brings one window forward on its own, as clicking it does, instead of activating its app, which
/// brings every window of the app forward. Uses the window server's private calls (the ones AltTab and
/// yabai use), looked up at run time; without them, callers activate the app instead.
enum WindowFocus {
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private static let functions: (ProcessForPID, SetFrontProcess, PostEventRecord)? = {
        let all = UnsafeMutableRawPointer(bitPattern: -2)
        guard let process = dlsym(all, "GetProcessForPID"), let front = dlsym(all, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(all, "SLPSPostEventRecordTo") else { return nil }
        return (unsafeBitCast(process, to: ProcessForPID.self), unsafeBitCast(front, to: SetFrontProcess.self),
                unsafeBitCast(post, to: PostEventRecord.self))
    }()

    /// Makes `window` the key window of its app, `pid`, and that app frontmost. Returns whether it could.
    @discardableResult
    static func focus(_ window: CGWindowID, of pid: pid_t) -> Bool {
        guard let (processForPID, setFrontProcess, postEventRecord) = functions else { return false }
        var process = ProcessSerialNumber()
        // 0x200: as if the user had clicked the window, which brings only it forward.
        guard processForPID(pid, &process) == noErr, setFrontProcess(&process, window, 0x200) == 0 else { return false }
        // Two synthetic window server events then make it the key window (worked out by Hammerspoon's users).
        var event = [UInt8](repeating: 0, count: 0xf8)
        event[0x04] = 0xf8
        event[0x3a] = 0x10
        withUnsafeBytes(of: window.littleEndian) { event.replaceSubrange(0x3c..<0x40, with: $0) }
        event.replaceSubrange(0x20..<0x30, with: repeatElement(UInt8(0xff), count: 0x10))
        for step: UInt8 in [1, 2] {
            event[0x08] = step
            _ = postEventRecord(&process, &event)
        }
        return true
    }
}
