import AppKit

/// Keeps one bar on every display except the one the real Dock is on, mirrors the Dock's
/// contents and settings into them, and carries out what the bars are asked to do.
@MainActor
final class BarManager: NSObject {
    let label = LabelPanel()
    private let makeAppMenu: () -> NSMenu
    private var bars: [CGDirectDisplayID: BarController] = [:]
    private var prefs = DockPrefs()
    private var tiles: [Tile] = []
    private var icons: [String: NSImage] = [:]
    private let iconStore = IconStore()
    private var dockDisplay: CGDirectDisplayID?
    private var visibleFrames: [CGDirectDisplayID: NSRect] = [:]
    private var dockTimer: Timer?
    private var prefsTimer: Timer?
    private var coverTimer: Timer?
    private var monitors: [Any] = []
    private var openableCache: [String: Bool] = [:]
    private var ticks = 0
    private var displays: [(screen: NSScreen, id: CGDirectDisplayID)] = []
    private var plistModified = 0
    private static let dockPlist = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
    private let running = RunningApps()
    private let windowKeeper = WindowKeeper()

    /// Shows the window picker for an app clicked in a bar (its icon's frame on screen, and the edge
    /// the bar is on). Returns whether it did, which it only does for apps with several windows.
    var pickWindow: ((NSRunningApplication, NSRect, DockOrientation) -> Bool)?

    init(appMenu: @escaping () -> NSMenu) {
        makeAppMenu = appMenu
        super.init()
    }

    /// Takes every bar down and stops watching, for when the tool is turned off.
    func stop() {
        for timer in [dockTimer, prefsTimer, coverTimer] { timer?.invalidate() }
        dockTimer = nil
        prefsTimer = nil
        coverTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        windowKeeper.stop()
        for bar in bars.values { bar.close() }
        bars.removeAll()
    }

    func start() {
        prefs = DockPrefs.read()
        refreshDisplays()
        dockDisplay = findDockDisplay()
        rebuildTiles(force: true)
        rebuildBars()
        dockTimer = repeatingTimer(0.3, #selector(dockTick(_:)))
        prefsTimer = repeatingTimer(2, #selector(prefsTick(_:)))
        updateCoverPolling()
        windowKeeper.strips = { [unowned self] in self.bars.values.compactMap(\.keepClearStrip) }
        updateWindowKeeper()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appWillLaunch(_:)), name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        // Apps usually change between regular and background as they activate or deactivate.
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(appsChanged(_:)), name: name, object: nil)
        }

        // The pointer, wherever it is. Mouse-moved monitors need no permission.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func repeatingTimer(_ interval: TimeInterval, _ selector: Selector) -> Timer {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Model

    private func rebuildTiles(force: Bool = false) {
        let new = TileBuilder.build(prefs: prefs, running: running.apps)
        guard force || new != tiles else { return }
        tiles = new
        icons = iconStore.icons(for: new)
        for bar in bars.values { configure(bar) }
    }

    /// The screens and their display IDs, refreshed when displays change (reading the ID builds a
    /// dictionary each time, and the Dock check runs every 0.3 s).
    private func refreshDisplays() {
        displays = NSScreen.screens.map { ($0, $0.displayID) }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        displays.first { $0.id == id }?.screen
    }

    private func configure(_ bar: BarController) {
        bar.configure(screen: screen(for: bar.displayID) ?? bar.screen, tiles: tiles, icons: icons, prefs: prefs)
    }

    private func rebuildBars() {
        let ids = Set(displays.map(\.id))
        for (id, bar) in bars where !ids.contains(id) {
            bar.close()
            bars[id] = nil
        }
        for (screen, id) in displays {
            let bar = bars[id] ?? BarController(screen: screen, manager: self)
            bars[id] = bar
            bar.isDockDisplay = id == dockDisplay
            bar.configure(screen: screen, tiles: tiles, icons: icons, prefs: prefs)
            bar.updateVisibility(.fade)
            visibleFrames[id] = screen.visibleFrame
        }
        appLog.info("Bars: \(self.bars.count, privacy: .public) displays, Dock on \(self.dockDisplay ?? 0, privacy: .public), \(self.tiles.count, privacy: .public) tiles")
    }

    /// The display whose visible frame is inset on the Dock's edge.
    private func findDockDisplay() -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, inset: CGFloat)?
        for (screen, id) in displays {
            let frame = screen.frame, visible = screen.visibleFrame
            let inset: CGFloat
            switch prefs.orientation {
            case .bottom: inset = visible.minY - frame.minY
            case .left: inset = visible.minX - frame.minX
            case .right: inset = frame.maxX - visible.maxX
            }
            if inset > 0.5 && inset > (best?.inset ?? 0) { best = (id, inset) }
        }
        if let best { return best.id }
        // No inset anywhere. An auto-hiding Dock shows none, so assume the main screen;
        // otherwise the Dock's display is probably showing a full-screen app, so keep what we had.
        if !prefs.autohide, let dockDisplay, screen(for: dockDisplay) != nil { return dockDisplay }
        return displays.first?.id
    }

    @objc private func dockTick(_ timer: Timer) {
        let id = findDockDisplay()
        if id != dockDisplay {
            appLog.info("Dock moved from display \(self.dockDisplay ?? 0, privacy: .public) to \(id ?? 0, privacy: .public)")
            dockDisplay = id
            for bar in bars.values where bar.isDockDisplay != (bar.displayID == id) {
                bar.isDockDisplay = bar.displayID == id
                configure(bar)
                bar.updateVisibility(.fade)
            }
        }
        // With "Also Show on the Dock's Display", that bar follows the Dock's size.
        for (screen, id) in displays where visibleFrames[id] != screen.visibleFrame {
            visibleFrames[id] = screen.visibleFrame
            if let bar = bars[id] { configure(bar) }
        }
    }

    @objc private func prefsTick(_ timer: Timer) {
        // Every 5 minutes, re-check every running app in case a change came without a notification.
        ticks += 1
        if ticks % 150 == 0 {
            running.resync()
            running.apps.forEach { windowKeeper.watch($0.pid) }
        }
        // Parsing the Dock's preferences is the costly part, so only do it when its plist has been
        // rewritten, or every 20 s in case a change hasn't reached the disk yet.
        var info = stat()
        let modified = stat(Self.dockPlist, &info) == 0 ? info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec : 0
        guard modified != plistModified || ticks % 10 == 0 else {
            rebuildTiles()
            return
        }
        plistModified = modified
        let new = DockPrefs.read()
        guard new != prefs else {
            rebuildTiles()
            return
        }
        let replace = new.orientation != prefs.orientation || new.autohide != prefs.autohide
        prefs = new
        rebuildTiles(force: true)
        if replace {
            dockDisplay = findDockDisplay()
            for bar in bars.values {
                bar.isDockDisplay = bar.displayID == dockDisplay
                configure(bar)
                bar.hideModeChanged()
            }
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        refreshDisplays()
        dockDisplay = findDockDisplay()
        rebuildBars()
    }

    // MARK: Settings

    func hideModeChanged() {
        updateCoverPolling()
        for bar in bars.values { bar.hideModeChanged() }
    }

    func showOnDockDisplayChanged() {
        for bar in bars.values {
            configure(bar)
            bar.updateVisibility(.fade)
        }
    }

    /// Starts or stops moving windows out from under the bars, following the setting and the permission.
    func updateWindowKeeper() {
        if Settings.shared.keepWindowsClear && Permissions.accessibilityAPIReady {
            windowKeeper.start(watching: running.apps)
        } else {
            windowKeeper.stop()
        }
    }

    /// Only "Hide When a Window Covers It" needs the window list.
    private func updateCoverPolling() {
        if Settings.shared.hideMode == .whenCovered {
            if coverTimer == nil { coverTimer = repeatingTimer(0.5, #selector(coverTick(_:))) }
            checkCovered()
        } else {
            coverTimer?.invalidate()
            coverTimer = nil
            for bar in bars.values { bar.covered = false }
        }
    }

    @objc private func coverTick(_ timer: Timer) {
        checkCovered()
    }

    private func checkCovered() {
        // Reading window bounds needs no permission (titles would).
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var windows: [NSRect] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != me,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 40, rect.height > 40 else { continue }
            // CG's origin is the top left of the main display; Cocoa's is its bottom left.
            windows.append(NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height))
        }
        for bar in bars.values {
            let barRect = bar.restingFrameOnScreen
            let covered = windows.contains { $0.intersects(barRect) }
            if covered != bar.covered {
                bar.covered = covered
                bar.updateVisibility(.slide)
            }
        }
    }

    // MARK: Pointer and apps

    func pointerMoved() {
        let point = NSEvent.mouseLocation
        for bar in bars.values { bar.pointerMoved(to: point) }
    }

    private func app(in note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    @objc private func appsChanged(_ note: Notification) {
        if let app = app(in: note) {
            running.update(app)
            if note.name == NSWorkspace.didTerminateApplicationNotification {
                windowKeeper.unwatch(app.processIdentifier)
            } else {
                watchWindows(of: app)
                if note.name == NSWorkspace.didActivateApplicationNotification { windowKeeper.snapshot(app.processIdentifier) }
            }
        }
        rebuildTiles()
    }

    @objc private func appWillLaunch(_ note: Notification) {
        guard let app = app(in: note) else { return }
        running.update(app)
        rebuildTiles()
        if prefs.animateLaunch, let id = tileID(for: app) { startBounce(id) }
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = app(in: note) else { return }
        running.update(app)
        watchWindows(of: app)
        rebuildTiles()
        if let id = tileID(for: app) { stopBounce(id) }
    }

    private func watchWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        if running.apps.contains(where: { $0.pid == pid }) { windowKeeper.watch(pid) }
    }

    private func tileID(for app: NSRunningApplication) -> String? {
        if let tile = tiles.first(where: { $0.pid == app.processIdentifier }) { return tile.id }
        if let bundleID = app.bundleIdentifier, let tile = tiles.first(where: { $0.kind == .app && $0.bundleID == bundleID }) {
            return tile.id
        }
        if let path = app.bundleURL.map(normalizedPath),
           let tile = tiles.first(where: { $0.kind == .app && $0.url.map(normalizedPath) == path }) {
            return tile.id
        }
        return nil
    }

    private func startBounce(_ id: String) {
        for bar in bars.values { bar.view.startBounce(id) }
    }

    private func stopBounce(_ id: String) {
        for bar in bars.values { bar.view.stopBounce(id) }
    }

    // MARK: Actions

    /// A click: apps launch or come forward (and reopen a window if they have none), the rest open.
    /// A running app with several windows shows the window picker instead, beside `icon` (its frame on screen).
    func open(_ tile: Tile, from icon: NSRect? = nil) {
        switch tile.kind {
        case .app:
            guard let url = tile.url else { return }
            if Settings.shared.windowPickerEnabled, let icon, let pid = tile.pid,
               let app = NSRunningApplication(processIdentifier: pid), pickWindow?(app, icon, prefs.orientation) == true {
                return
            }
            let id = tile.id
            if !tile.isRunning && prefs.animateLaunch { startBounce(id) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    appLog.error("Couldn't open \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.stopBounce(id)
                }
            }
        case .folder, .file, .url:
            if let url = tile.url { NSWorkspace.shared.open(url) }
        case .trash:
            NSWorkspace.shared.open(TileBuilder.trashURL)
        case .spacer, .smallSpacer, .separator:
            break
        }
    }

    func appMenu() -> NSMenu { makeAppMenu() }

    func menu(for tile: Tile) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = tile
            menu.addItem(item)
            return item
        }
        switch tile.kind {
        case .app:
            if let pid = tile.pid, let app = NSRunningApplication(processIdentifier: pid) {
                add(app.isHidden ? "Show" : "Hide", #selector(hideOrShow(_:)))
                menu.addItem(.separator())
                add("Show in Finder", #selector(showInFinder(_:)))
                if !tile.isFinder {
                    menu.addItem(.separator())
                    add("Quit", #selector(quit(_:)))
                    let forceQuit = add("Force Quit", #selector(forceQuit(_:)))
                    forceQuit.keyEquivalentModifierMask = .option
                    forceQuit.isAlternate = true
                }
            } else {
                add("Open", #selector(openItem(_:)))
                add("Show in Finder", #selector(showInFinder(_:)))
            }
        case .folder, .file:
            add("Open", #selector(openItem(_:)))
            add("Show in Finder", #selector(showInFinder(_:)))
        case .url, .trash:
            add("Open", #selector(openItem(_:)))
        case .spacer, .smallSpacer, .separator:
            break
        }
        return menu
    }

    private func runningApp(_ sender: NSMenuItem) -> NSRunningApplication? {
        guard let pid = (sender.representedObject as? Tile)?.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    @objc private func hideOrShow(_ sender: NSMenuItem) {
        guard let app = runningApp(sender), let tile = sender.representedObject as? Tile else { return }
        if app.isHidden { open(tile) } else { app.hide() }
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? Tile)?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit(_ sender: NSMenuItem) {
        runningApp(sender)?.terminate()
    }

    @objc private func forceQuit(_ sender: NSMenuItem) {
        runningApp(sender)?.forceTerminate()
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        if let tile = sender.representedObject as? Tile { open(tile) }
    }

    // MARK: Drops

    /// Apps take files they can open (or anything with Command held), the Trash takes anything.
    func dropOperation(for tile: Tile, urls: [URL], allowed: NSDragOperation) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        switch tile.kind {
        case .trash:
            for operation in [NSDragOperation.delete, .move, .generic] where allowed.contains(operation) { return operation }
        case .app:
            guard let appURL = tile.url else { return [] }
            guard NSEvent.modifierFlags.contains(.command) || canOpen(urls, with: appURL, bundleID: tile.bundleID) else { return [] }
            for operation in [NSDragOperation.generic, .copy, .link] where allowed.contains(operation) { return operation }
        default:
            break
        }
        return []
    }

    private func canOpen(_ urls: [URL], with appURL: URL, bundleID: String?) -> Bool {
        let appPath = normalizedPath(appURL)
        let key = appPath + "\n" + urls.map(\.path).joined(separator: "\n")
        if let cached = openableCache[key] { return cached }
        let result = urls.allSatisfy { url in
            NSWorkspace.shared.urlsForApplications(toOpen: url).contains { candidate in
                normalizedPath(candidate) == appPath || (bundleID != nil && TileBuilder.bundleID(at: candidate) == bundleID)
            }
        }
        if openableCache.count > 200 { openableCache.removeAll() }
        openableCache[key] = result
        return result
    }

    func drop(_ urls: [URL], on tile: Tile) -> Bool {
        guard !urls.isEmpty else { return false }
        switch tile.kind {
        case .trash:
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { appLog.error("Moving to the Trash failed: \(error.localizedDescription, privacy: .public)") }
            }
            return true
        case .app:
            guard let appURL = tile.url else { return false }
            let id = tile.id
            if !tile.isRunning && prefs.animateLaunch { startBounce(id) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
                guard error != nil else { return }
                Task { @MainActor in self.stopBounce(id) }
            }
            return true
        default:
            return false
        }
    }
}
