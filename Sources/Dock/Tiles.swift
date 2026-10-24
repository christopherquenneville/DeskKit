import AppKit
import UniformTypeIdentifiers

enum TileKind: Equatable {
    case app, folder, file, url, spacer, smallSpacer, separator, trash
}

/// One slot of a bar, in the Dock's order.
struct Tile: Equatable {
    var id: String
    var kind: TileKind
    var label = ""
    var url: URL?
    var bundleID: String?
    var pid: pid_t?
    var isFinder = false
    var hidden = false
    var trashFull = false
    var badge: String?

    var isRunning: Bool { pid != nil }

    var isActionable: Bool {
        switch kind {
        case .app, .folder, .file, .url, .trash: return true
        case .spacer, .smallSpacer, .separator: return false
        }
    }
}

/// A running app that shows in the Dock, with the details DeskKit needs copied out once.
/// (Reading them from NSRunningApplication can mean a round trip to launchservicesd every time.)
struct RunningApp {
    let pid: pid_t
    let bundleID: String?
    let bundleURL: URL?
    let path: String?
    let launchDate: Date?
    let name: String?
    let app: NSRunningApplication

    init(_ app: NSRunningApplication) {
        self.app = app
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        bundleURL = app.bundleURL
        path = app.bundleURL.map(normalizedPath)
        launchDate = app.launchDate
        name = app.localizedName
    }
}

/// The running apps that show in the Dock (activation policy `.regular`).
///
/// There are dozens of background apps, and asking each for its policy is a round trip to
/// launchservicesd, so the list is built once and then kept up to date from workspace
/// notifications, with a full re-check every 5 minutes in case one was missed.
@MainActor
final class RunningApps {
    private(set) var apps: [RunningApp] = []
    private let me = ProcessInfo.processInfo.processIdentifier

    init() { resync() }

    func resync() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != me && !$0.isTerminated && $0.activationPolicy == .regular }
            .map(RunningApp.init)
    }

    /// Re-checks one app after it launched, quit, activated, deactivated, hid or unhid.
    func update(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        apps.removeAll { $0.pid == pid }
        if pid != me && !app.isTerminated && app.activationPolicy == .regular {
            apps.append(RunningApp(app))
        }
    }
}

/// Builds the tile list the way the Dock orders it: Finder, pinned apps, running apps that
/// aren't pinned (oldest first), a separator, pinned folders and files, then the Trash.
@MainActor
enum TileBuilder {
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    static let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    private static var bundleIDs: [String: String] = [:]

    static func bundleID(at url: URL) -> String? {
        let path = normalizedPath(url)
        if let cached = bundleIDs[path] { return cached.isEmpty ? nil : cached }
        let id = Bundle(url: url)?.bundleIdentifier ?? ""
        bundleIDs[path] = id
        return id.isEmpty ? nil : id
    }

    static func build(prefs: DockPrefs, running: [RunningApp]) -> [Tile] {
        var pool = running

        // Match by bundle id first, then by path (Safari runs from a cryptex, not /Applications).
        func claim(bundleID: String?, url: URL?) -> RunningApp? {
            if let bundleID, let i = pool.firstIndex(where: { $0.bundleID == bundleID }) {
                return pool.remove(at: i)
            }
            if let url {
                let path = normalizedPath(url)
                if let i = pool.firstIndex(where: { $0.path == path }) {
                    return pool.remove(at: i)
                }
            }
            return nil
        }

        var tiles: [Tile] = []
        var ids = Set<String>()
        func add(_ tile: Tile) {
            var tile = tile
            if ids.contains(tile.id) { tile.id += "#\(tile.pid ?? Int32(tiles.count))" }
            ids.insert(tile.id)
            tiles.append(tile)
        }
        func appTile(_ app: RunningApp?, label: String, url: URL?, bundleID: String?) -> Tile {
            let key = bundleID ?? url.map(normalizedPath) ?? "pid\(app?.pid ?? 0)"
            var tile = Tile(id: "app:" + key, kind: .app, label: label, url: url ?? app?.bundleURL, bundleID: bundleID)
            if let app {
                tile.pid = app.pid
                if prefs.dimHiddenApps { tile.hidden = app.app.isHidden }
                tile.badge = BadgeReader.badge(for: app.pid)
            }
            return tile
        }

        var finder = appTile(claim(bundleID: "com.apple.finder", url: finderURL),
                             label: "Finder", url: finderURL, bundleID: "com.apple.finder")
        finder.isFinder = true
        add(finder)

        for (index, item) in prefs.apps.enumerated() {
            switch item.kind {
            case .spacer, .smallSpacer:
                if !prefs.showOnlyRunning {
                    add(Tile(id: "spacer:apps:\(index)", kind: item.kind == .spacer ? .spacer : .smallSpacer))
                }
            default:
                guard let url = item.url else { continue }
                let bundleID = item.bundleID ?? bundleID(at: url)
                let app = claim(bundleID: bundleID, url: url)
                if prefs.showOnlyRunning && app == nil { continue }
                add(appTile(app, label: item.label, url: url, bundleID: bundleID))
            }
        }

        let unpinned = pool.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        pool.removeAll()
        func runningTile(_ app: RunningApp) -> Tile {
            appTile(app, label: app.name ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                    url: app.bundleURL, bundleID: app.bundleID)
        }
        if prefs.showRecents && !prefs.showOnlyRunning {
            // "Show suggested and recent apps": a section of its own between separators.
            var section: [Tile] = []
            var used = Set<pid_t>()
            for item in prefs.recents where item.kind == .app {
                guard let url = item.url else { continue }
                let bundleID = item.bundleID ?? bundleID(at: url)
                if tiles.contains(where: { $0.bundleID != nil && $0.bundleID == bundleID }) { continue }
                let app = unpinned.first { $0.bundleID == bundleID && !used.contains($0.pid) }
                if let app { used.insert(app.pid) }
                section.append(appTile(app, label: item.label, url: url, bundleID: bundleID))
            }
            section += unpinned.filter { !used.contains($0.pid) }.map(runningTile)
            if !section.isEmpty {
                add(Tile(id: "separator:recents", kind: .separator))
                section.forEach(add)
            }
        } else {
            unpinned.map(runningTile).forEach(add)
        }

        add(Tile(id: "separator", kind: .separator))

        if !prefs.showOnlyRunning {
            for (index, item) in prefs.others.enumerated() {
                switch item.kind {
                case .spacer, .smallSpacer:
                    add(Tile(id: "spacer:others:\(index)", kind: item.kind == .spacer ? .spacer : .smallSpacer))
                case .folder:
                    add(Tile(id: "folder:" + (item.url.map(normalizedPath) ?? "\(index)"), kind: .folder, label: item.label, url: item.url))
                case .file:
                    add(Tile(id: "file:" + (item.url.map(normalizedPath) ?? "\(index)"), kind: .file, label: item.label, url: item.url))
                case .url:
                    add(Tile(id: "url:" + (item.url?.absoluteString ?? "\(index)"), kind: .url, label: item.label, url: item.url))
                case .app:
                    guard let url = item.url else { continue }
                    let bundleID = item.bundleID ?? bundleID(at: url)
                    add(appTile(nil, label: item.label, url: url, bundleID: bundleID))
                }
            }
        }

        var trash = Tile(id: "trash", kind: .trash, label: "Trash", url: trashURL)
        trash.trashFull = prefs.trashFull
        add(trash)
        return tiles
    }
}

/// Reads the badge an app shows on its Dock icon ("3", "69", "!") from LaunchServices.
/// This is private API, so it is looked up at run time and simply returns nil if it's missing.
enum BadgeReader {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyInformation = @convention(c) (Int32, CFTypeRef, CFArray?) -> Unmanaged<CFDictionary>?

    private static let functions: (CreateASN, CopyInformation)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformation") else { return nil }
        return (unsafeBitCast(create, to: CreateASN.self), unsafeBitCast(copy, to: CopyInformation.self))
    }()

    static func badge(for pid: pid_t) -> String? {
        guard let (createASN, copyInformation) = functions,
              let asn = createASN(nil, pid)?.takeRetainedValue(),
              let info = copyInformation(-2, asn, ["StatusLabel"] as CFArray)?.takeRetainedValue() as? [String: Any],
              let label = (info["StatusLabel"] as? [String: Any])?["label"] as? String,
              !label.isEmpty else { return nil }
        return label
    }
}

/// Icons for tiles, cached by what they show.
@MainActor
final class IconStore {
    private var cache: [String: NSImage] = [:]

    func reset() { cache.removeAll() }

    func icons(for tiles: [Tile]) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for tile in tiles {
            if let icon = icon(for: tile) { icons[tile.id] = icon }
        }
        return icons
    }

    private func icon(for tile: Tile) -> NSImage? {
        let key: String
        switch tile.kind {
        case .spacer, .smallSpacer, .separator: return nil
        case .trash: key = tile.trashFull ? "trash:full" : "trash:empty"
        default: key = "\(tile.kind):" + (tile.url?.absoluteString ?? "pid\(tile.pid ?? 0)")
        }
        if let cached = cache[key] { return cached }
        let icon = load(tile)
        cache[key] = icon
        return icon
    }

    private func load(_ tile: Tile) -> NSImage {
        switch tile.kind {
        case .trash:
            // The Dock's own glass trash is composited live; CoreTypes has the same artwork.
            let name = tile.trashFull ? "FullTrashIcon" : "TrashIcon"
            return NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns")
                ?? NSImage(named: tile.trashFull ? NSImage.trashFullName : NSImage.trashEmptyName)
                ?? NSImage()
        case .url:
            return NSWorkspace.shared.icon(for: UTType("com.apple.web-internet-location") ?? .url)
        default:
            if let url = tile.url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            if let pid = tile.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                return icon
            }
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}
