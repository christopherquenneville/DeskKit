import Foundation

enum HideMode: Int {
    case never = 0
    case whenCovered = 1
    case always = 2
    /// Hide exactly when the Dock itself auto-hides.
    case sameAsDock = 3
}

/// DeskKit's own preferences. The Dock's preferences are only ever read (see DockPrefs).
@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // MARK: Tools

    /// A copy of the Dock on every display that doesn't have it.
    var dockEnabled: Bool {
        get { defaults.object(forKey: "DockEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "DockEnabled") }
    }

    /// Clicking an app with several windows, in the Dock or a bar, shows a window picker.
    var windowPickerEnabled: Bool {
        get { defaults.object(forKey: "WindowPickerEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "WindowPickerEnabled") }
    }

    /// Mouse wheels scroll the other way from trackpads, which keep the system's direction.
    var reverseMouseWheel: Bool {
        get { defaults.bool(forKey: "ReverseMouseWheel") }
        set { defaults.set(newValue, forKey: "ReverseMouseWheel") }
    }

    // MARK: Dock options

    var hideMode: HideMode {
        get {
            guard let raw = defaults.object(forKey: "HideMode") as? Int else { return .sameAsDock }
            return HideMode(rawValue: raw) ?? .sameAsDock
        }
        set { defaults.set(newValue.rawValue, forKey: "HideMode") }
    }

    var showOnDockDisplay: Bool {
        get { defaults.bool(forKey: "ShowOnDockDisplay") }
        set { defaults.set(newValue, forKey: "ShowOnDockDisplay") }
    }

    /// Move zoomed and tiled windows out from under the bars (needs Accessibility access).
    var keepWindowsClear: Bool {
        get { defaults.object(forKey: "KeepWindowsClear") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "KeepWindowsClear") }
    }

    /// Hidden option: use the pre-Liquid Glass background even on macOS 26 and later.
    var legacyBackground: Bool { defaults.bool(forKey: "LegacyBackground") }

    // MARK: App

    var showInMenuBar: Bool {
        get { defaults.object(forKey: "ShowInMenuBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ShowInMenuBar") }
    }

    var didSetUpLoginItem: Bool {
        get { defaults.bool(forKey: "DidSetUpLoginItem") }
        set { defaults.set(newValue, forKey: "DidSetUpLoginItem") }
    }

    var declinedMoveToApplications: Bool {
        get { defaults.bool(forKey: "DeclinedMoveToApplications") }
        set { defaults.set(newValue, forKey: "DeclinedMoveToApplications") }
    }

    var didExplainHiddenMenuBarIcon: Bool {
        get { defaults.bool(forKey: "DidExplainHiddenMenuBarIcon") }
        set { defaults.set(newValue, forKey: "DidExplainHiddenMenuBarIcon") }
    }

    /// The build that last explained and asked for permissions, so each build asks at most once.
    var askedForPermissionsInBuild: String {
        get { defaults.string(forKey: "AskedForPermissionsInBuild") ?? "" }
        set { defaults.set(newValue, forKey: "AskedForPermissionsInBuild") }
    }

    /// Both permissions were asked for at once: once Accessibility is allowed (which can be after a
    /// restart), System Settings moves on to Screen Recording.
    var showScreenRecordingSettingsNext: Bool {
        get { defaults.bool(forKey: "ShowScreenRecordingSettingsNext") }
        set { defaults.set(newValue, forKey: "ShowScreenRecordingSettingsNext") }
    }

    /// The build that last restarted itself so a new Accessibility grant took effect, so it never
    /// does that twice.
    var restartedForAccessibilityInBuild: String {
        get { defaults.string(forKey: "RestartedForAccessibilityInBuild") ?? "" }
        set { defaults.set(newValue, forKey: "RestartedForAccessibilityInBuild") }
    }
}
