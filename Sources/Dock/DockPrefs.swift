import AppKit

enum DockOrientation: String {
    case bottom, left, right
}

struct DockItem: Equatable {
    enum Kind: Equatable { case app, folder, file, url, spacer, smallSpacer }
    var kind: Kind
    var label = ""
    var url: URL?
    var bundleID: String?
}

/// A snapshot of the Dock's preferences (com.apple.dock). DeskKit only ever reads them;
/// pinning, removing and resizing stay the real Dock's job.
struct DockPrefs: Equatable {
    var apps: [DockItem] = []
    var others: [DockItem] = []
    var recents: [DockItem] = []
    var tileSize: CGFloat = 48
    var magnification = false
    var largeSize: CGFloat = 64
    var orientation: DockOrientation = .bottom
    var autohide = false
    var autohideDelay: Double = 0
    var autohideTimeModifier: Double = 1
    var showIndicators = true
    var showRecents = true
    var showOnlyRunning = false
    var dimHiddenApps = false
    var animateLaunch = true
    var trashFull = false

    static var domain: CFString { "com.apple.dock" as CFString }

    static func read() -> DockPrefs {
        // The Dock posts nothing when its preferences change, so callers poll this.
        CFPreferencesAppSynchronize(domain)
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
        func number(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        func flag(_ key: String) -> Bool? { (value(key) as? NSNumber)?.boolValue }

        var prefs = DockPrefs()
        prefs.apps = items(value("persistent-apps"), inAppsSection: true)
        prefs.others = items(value("persistent-others"), inAppsSection: false)
        prefs.recents = items(value("recent-apps"), inAppsSection: true)
        if let size = number("tilesize") { prefs.tileSize = CGFloat(min(max(size, 16), 128)) }
        prefs.magnification = flag("magnification") ?? false
        if let size = number("largesize") { prefs.largeSize = CGFloat(min(max(size, 16), 128)) }
        prefs.orientation = DockOrientation(rawValue: value("orientation") as? String ?? "") ?? .bottom
        prefs.autohide = flag("autohide") ?? false
        prefs.autohideDelay = max(0, number("autohide-delay") ?? 0)
        prefs.autohideTimeModifier = max(0, number("autohide-time-modifier") ?? 1)
        prefs.showIndicators = flag("show-process-indicators") ?? true
        prefs.showRecents = flag("show-recents") ?? true
        prefs.showOnlyRunning = flag("static-only") ?? false
        prefs.dimHiddenApps = flag("showhidden") ?? false
        prefs.animateLaunch = flag("launchanim") ?? true
        prefs.trashFull = flag("trash-full") ?? false
        return prefs
    }

    private static func items(_ raw: Any?, inAppsSection: Bool) -> [DockItem] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let type = entry["tile-type"] as? String
            let data = entry["tile-data"] as? [String: Any] ?? [:]
            switch type {
            case "spacer-tile":
                return DockItem(kind: .spacer)
            case "small-spacer-tile":
                return DockItem(kind: .smallSpacer)
            case "url-tile":
                guard let string = (data["url"] as? [String: Any])?["_CFURLString"] as? String,
                      let url = URL(string: string) else { return nil }
                return DockItem(kind: .url, label: data["label"] as? String ?? url.host ?? string, url: url)
            case "file-tile", "directory-tile":
                guard let url = fileURL(data["file-data"]) else { return nil }
                let kind: DockItem.Kind
                if type == "directory-tile" {
                    kind = .folder
                } else {
                    kind = inAppsSection || url.pathExtension == "app" ? .app : .file
                }
                let label = data["file-label"] as? String ?? FileManager.default.displayName(atPath: url.path)
                return DockItem(kind: kind, label: label, url: url, bundleID: data["bundle-identifier"] as? String)
            default:
                return nil
            }
        }
    }

    /// `_CFURLString` is a file:// URL when `_CFURLStringType` is 15, and a plain path when it is 0.
    private static func fileURL(_ raw: Any?) -> URL? {
        guard let data = raw as? [String: Any], let string = data["_CFURLString"] as? String else { return nil }
        if (data["_CFURLStringType"] as? NSNumber)?.intValue == 0 { return URL(fileURLWithPath: string) }
        return URL(string: string)
    }
}
