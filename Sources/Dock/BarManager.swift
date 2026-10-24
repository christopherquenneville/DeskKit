import AppKit

/// Keeps one bar on every display except the one the real Dock is on, mirrors the Dock's
/// contents and settings into them, and carries out what the bars are asked to do.
///
/// It never watches the pointer system-wide: each bar hears about it only while the pointer is over
/// it (or over the edge sensor of a hidden bar), and with a single display, where no bar can show,
/// it stops following the Dock and other apps' windows altogether.
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
    private var prefsTimer: Timer?
    private var coverTimer: Timer?
    private var pointerTimer: Timer?
    private var dockWatchTimer: Timer?
    private var dockWatchTicks = 0
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
        for timer in [prefsTimer, coverTimer, pointerTimer, dockWatchTimer] { timer?.invalidate() }
        prefsTimer = nil
        coverTimer = nil
        pointerTimer = nil
        dockWatchTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        windowKeeper.strips = { [unowned self] in self.bars.values.compactMap(\.keepClearStrip) }
        updateActivity()

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
    }

    private func repeatingTimer(_ interval: TimeInterval, _ selector: Selector) -> Timer {
        let timer = Timer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Whether any bar can show at all: not with a single display, unless a bar is wanted beside the Dock.
    private var barsCanShow: Bool {
        displays.count > 1 || Settings.shared.showOnDockDisplay
    }

    /// Following the Dock's settings and display, and checking for covering windows, only matter
    /// while a bar can show; on one display DeskKit goes quiet until another display arrives.
    private func updateActivity() {
        if barsCanShow {
            if prefsTimer == nil {
                prefsTimer = repeatingTimer(2, #selector(prefsTick(_:)))
                refreshPrefs(force: true)
            }
        } else {
            for timer in [prefsTimer, dockWatchTimer] { timer?.invalidate() }
            prefsTimer = nil
            dockWatchTimer = nil
        }
        updateCoverPolling()
        updateWindowKeeper()
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
    /// dictionary each time, and the Dock check runs often while the pointer pushes an edge).
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

    /// Moves the bars around when the Dock has moved to another display, and follows changes in
    /// the displays' visible frames.
    private func checkDockDisplay() {
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

    /// The Dock moves to a display when the pointer pushes against that display's Dock edge, so
    /// while that happens, look for it four times a second for two seconds.
    private func watchForDockMove() {
        dockWatchTicks = 0
        guard dockWatchTimer == nil else { return }
        appLog.debug("The pointer is at a Dock edge; watching for the Dock to move")
        dockWatchTimer = repeatingTimer(0.25, #selector(dockWatchTick(_:)))
    }

    @objc private func dockWatchTick(_ timer: Timer) {
        checkDockDisplay()
        dockWatchTicks += 1
        if dockWatchTicks >= 8 {
            timer.invalidate()
            dockWatchTimer = nil
        }
    }

    @objc private func prefsTick(_ timer: Timer) {
        // Anything that moved the Dock without the pointer pushing an edge is caught here.
        checkDockDisplay()
        refreshPrefs(force: false)
    }

    private func refreshPrefs(force: Bool) {
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
        guard force || modified != plistModified || ticks % 10 == 0 else {
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
            updateWindowKeeper()
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        refreshDisplays()
        dockDisplay = findDockDisplay()
        rebuildBars()
        updateActivity()
    }

    // MARK: Settings

    func hideModeChanged() {
        updateActivity()
        for bar in bars.values { bar.hideModeChanged() }
    }

    func showOnDockDisplayChanged() {
        for bar in bars.values {
            configure(bar)
            bar.updateVisibility(.fade)
        }
        updateActivity()
    }

    /// Starts or stops moving windows out from under the bars: only while some bar stays on screen,
    /// and with the setting and the permission.
    func updateWindowKeeper() {
        let mode = Settings.shared.hideMode
        let barsStay = mode == .never || (mode == .sameAsDock && !prefs.autohide)
        if Settings.shared.keepWindowsClear && Permissions.accessibilityAPIReady && barsCanShow && barsStay {
            windowKeeper.start(watching: running.apps)
        } else {
            windowKeeper.stop()
        }
    }

    /// Only "Hide When a Window Covers It" needs the window list, and only while a bar can show.
    private func updateCoverPolling() {
        if Settings.shared.hideMode == .whenCovered && barsCanShow {
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

    /// The pointer is over a bar or an edge sensor (or a poll asked): let every bar update.
    func pointerMoved() {
        let point = NSEvent.mouseLocation
        for bar in bars.values { bar.pointerMoved(to: point) }
        if isPushingDockEdge(point) { watchForDockMove() }
        updatePointerPolling()
    }

    /// The pointer is on the Dock's edge of a display that doesn't have the Dock.
    private func isPushingDockEdge(_ point: NSPoint) -> Bool {
        for (screen, id) in displays where id != dockDisplay {
            let f = screen.frame
            guard point.x >= f.minX, point.x <= f.maxX, point.y >= f.minY, point.y <= f.maxY else { continue }
            switch prefs.orientation {
            case .bottom: return point.y <= f.minY + 1
            case .left: return point.x <= f.minX + 1
            case .right: return point.x >= f.maxX - 1
            }
        }
        return false
    }

    /// Polls the pointer twenty times a second, but only while a bar needs it (see
    /// `BarController.needsPointerPolling`); at all other times nothing runs.
    func updatePointerPolling() {
        let needed = bars.values.contains { $0.needsPointerPolling }
        if needed && pointerTimer == nil {
            pointerTimer = repeatingTimer(1.0 / 20.0, #selector(pointerTick(_:)))
        } else if !needed, let timer = pointerTimer {
            timer.invalidate()
            pointerTimer = nil
        }
    }

    @objc private func pointerTick(_ timer: Timer) {
        pointerMoved()
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
