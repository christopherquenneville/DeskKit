import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The two permissions DeskKit can use, and honest ways to check them.
@MainActor
enum Permissions {
    /// Accessibility, which macOS 27 lists as "Device Control and Data Access". Needed to move other
    /// apps' windows, reverse the mouse wheel and catch clicks on the Dock.
    ///
    /// AXIsProcessTrusted() can stay stale for the life of the process after access is granted, so
    /// when it says no, briefly creating an event tap (which needs the same permission) settles it.
    static var accessibility: Bool {
        if AXIsProcessTrusted() { return true }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                          userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    /// Whether this process can actually use the Accessibility API yet. When access was granted while
    /// DeskKit was running, it may need a fresh start before the API answers.
    static var accessibilityAPIReady: Bool { AXIsProcessTrusted() }

    /// Screen & System Audio Recording, for window previews in the picker.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// What System Settings calls each permission on this version of macOS.
    static var accessibilityName: String { atLeast(27) ? "Device Control and Data Access" : "Accessibility" }
    static var screenRecordingName: String { atLeast(15) ? "Screen & System Audio Recording" : "Screen Recording" }

    /// Shows macOS's prompt, which also lists DeskKit under Accessibility, and opens that list.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings("Privacy_Accessibility") }
    }

    /// Shows macOS's prompt, which also lists DeskKit under Screen Recording, and opens that list if
    /// asked. On current macOS only a ScreenCaptureKit request adds DeskKit to the list; the older
    /// call does it on macOS 12 and 13.
    static func requestScreenRecording(thenOpenSettings open: Bool) {
        if #available(macOS 14, *) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in
                if open { Task { @MainActor in openScreenRecordingSettings() } }
            }
        } else {
            _ = CGRequestScreenCaptureAccess()
            if open { openScreenRecordingSettings() }
        }
    }

    static func openScreenRecordingSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    private static func openSettings(_ anchor: String) {
        let pane = atLeast(13) ? "com.apple.settings.PrivacySecurity.extension" : "com.apple.preference.security"
        if let url = URL(string: "x-apple.systempreferences:\(pane)?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    private static func atLeast(_ major: Int) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0))
    }

    /// Identifies this exact build (when its executable was made), so each build asks at most once.
    static var buildIdentity: String {
        guard let path = Bundle.main.executablePath,
              let made = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "" }
        return String(made.timeIntervalSince1970)
    }
}

/// Starts the copy of DeskKit at `url` once this process has quit, so it isn't mistaken for a second instance.
@MainActor
func relaunch(_ url: URL = Bundle.main.bundleURL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", url.path]
    try? process.run()
    NSApp.terminate(nil)
}
