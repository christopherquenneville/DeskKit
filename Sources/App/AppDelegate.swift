import AppKit

/// Runs DeskKit's tools (a Dock on every display, the window picker and the reversed mouse wheel),
/// following their settings and the permissions macOS has given, and its menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let showIconNotification = Notification.Name("tech.quenneville.DeskKit.showMenuBarIcon")

    private var bars: BarManager?
    private let picker = WindowPicker()
    private let dockClicks = DockClickWatcher()
    private let scroll = ScrollFlipper()
    private let updater = Updater()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var activity: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var hasAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy runs. A second launch brings the first one's menu bar icon back.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Self.showIconNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        if Relocator.offerToMoveIfNeeded() { return }

        NSApp.disableRelaunchOnLogin()
        // Keep App Nap from stretching the timers that follow the Dock while every bar is hidden.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Keeping the bars in step with the Dock")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showIconRequested(_:)),
                                                            name: Self.showIconNotification, object: nil)
        if Relocator.isInApplications && !Settings.shared.didSetUpLoginItem {
            Settings.shared.didSetUpLoginItem = true
            LoginItem.setEnabled(true)
        }
        // An app that hangs mustn't freeze DeskKit (or a click on the Dock): give up on it after half a second.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        statusMenu.delegate = self
        updateStatusItem()
        dockClicks.onClick = { [unowned self] app, windows, icon, edge in
            self.picker.show(for: app, windows: windows, anchor: icon, edge: edge)
        }
        hasAccessibility = Permissions.accessibility
        updateTools()
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(checkPermissions(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        askForPermissionsIfNeeded()
        updater.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuBarIcon()
        return false
    }

    // MARK: Tools

    /// Starts or stops each tool to match its setting and what DeskKit is allowed to do.
    private func updateTools() {
        let settings = Settings.shared
        if settings.dockEnabled {
            if let bars {
                bars.updateWindowKeeper()
            } else {
                let bars = BarManager(appMenu: { [unowned self] in self.makeAppMenu() })
                bars.pickWindow = { [unowned self] app, icon, edge in self.picker.show(for: app, anchor: icon, edge: edge) }
                self.bars = bars
                bars.start()
            }
        } else if let bars {
            bars.stop()
            self.bars = nil
        }
        if settings.windowPickerEnabled && hasAccessibility {
            if !dockClicks.start() { appLog.error("Couldn't watch clicks on the Dock") }
        } else {
            dockClicks.stop()
            picker.dismiss()
        }
        if settings.reverseMouseWheel && hasAccessibility {
            if !scroll.start() { appLog.error("Couldn't reverse the mouse wheel") }
        } else {
            scroll.stop()
        }
    }

    /// Whether a tool that's turned on needs Accessibility access (the Docks themselves don't).
    private var wantsAccessibility: Bool {
        let settings = Settings.shared
        return settings.windowPickerEnabled || settings.reverseMouseWheel || (settings.dockEnabled && settings.keepWindowsClear)
    }

    // MARK: Permissions

    @objc private func checkPermissions(_ timer: Timer) {
        let allowed = Permissions.accessibility
        if allowed && !Permissions.accessibilityAPIReady && Settings.shared.restartedForAccessibilityInBuild != Permissions.buildIdentity {
            // Access was just allowed, but this process's Accessibility API can stay shut until it starts again.
            Settings.shared.restartedForAccessibilityInBuild = Permissions.buildIdentity
            appLog.info("Restarting so the new Accessibility access takes effect")
            relaunch()
            return
        }
        if allowed != hasAccessibility {
            hasAccessibility = allowed
            appLog.info("Accessibility access is \(allowed ? "on" : "off", privacy: .public)")
            updateTools()
        }
        if allowed && Settings.shared.showScreenRecordingSettingsNext {
            // Accessibility is done: move System Settings on to the other permission.
            Settings.shared.showScreenRecordingSettingsNext = false
            if Settings.shared.windowPickerEnabled && !Permissions.screenRecording { Permissions.openScreenRecordingSettings() }
        }
    }

    /// Explains and asks for what the turned-on tools need, once per build of DeskKit.
    private func askForPermissionsIfNeeded() {
        let settings = Settings.shared
        let needsAccessibility = wantsAccessibility && !hasAccessibility
        let needsScreenRecording = settings.windowPickerEnabled && !Permissions.screenRecording
        guard needsAccessibility || needsScreenRecording, settings.askedForPermissionsInBuild != Permissions.buildIdentity else { return }
        settings.askedForPermissionsInBuild = Permissions.buildIdentity
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if needsAccessibility {
            alert.messageText = "Allow DeskKit to work with your windows"
            alert.informativeText = "To show the window picker, keep zoomed windows clear of its Docks and reverse the mouse wheel, "
                + "DeskKit needs to be turned on in System Settings › Privacy & Security › \(Permissions.accessibilityName). "
                + "Its Docks work without it."
            if needsScreenRecording {
                alert.informativeText += "\n\nTurn it on under \(Permissions.screenRecordingName) too, so the window picker can show previews of your windows."
            }
        } else {
            alert.messageText = "Show window previews?"
            alert.informativeText = "With \(Permissions.screenRecordingName) access, the window picker shows a preview of each window. "
                + "Without it, the picker shows the app's icon instead."
        }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // macOS's own prompts for both at once; Settings opens at the first and moves on to the second
        // once Accessibility is on.
        if needsAccessibility {
            if needsScreenRecording { Permissions.requestScreenRecording(thenOpenSettings: false) }
            settings.showScreenRecordingSettingsNext = needsScreenRecording
            Permissions.requestAccessibility()
        } else {
            Permissions.requestScreenRecording(thenOpenSettings: true)
        }
    }

    // MARK: Menu bar icon

    @objc private func showIconRequested(_ note: Notification) {
        showMenuBarIcon()
    }

    private func showMenuBarIcon() {
        Settings.shared.showInMenuBar = true
        updateStatusItem()
    }

    private func updateStatusItem() {
        if Settings.shared.showInMenuBar {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DeskKit")
                ?? NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DeskKit")
            image?.isTemplate = true
            item.button?.image = image
            item.menu = statusMenu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: Menu (menu bar icon, and a right-click on a bar's background)

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    private func makeAppMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared
        addToggle(to: menu, "Dock on Every Display", #selector(toggleDock(_:)), settings.dockEnabled)
        let options = NSMenuItem(title: "Dock Options", action: nil, keyEquivalent: "")
        options.submenu = makeDockOptions()
        menu.addItem(options)
        addToggle(to: menu, needingAccess("Window Picker", settings.windowPickerEnabled), #selector(toggleWindowPicker(_:)),
                  settings.windowPickerEnabled)
        addToggle(to: menu, needingAccess("Reverse Mouse Wheel", settings.reverseMouseWheel), #selector(toggleReverseMouseWheel(_:)),
                  settings.reverseMouseWheel)

        var access: [NSMenuItem] = []
        if wantsAccessibility && !hasAccessibility {
            access.append(item("Allow DeskKit in \(Permissions.accessibilityName)…", #selector(allowAccessibility(_:))))
        } else if hasAccessibility && !Permissions.accessibilityAPIReady {
            access.append(item("Restart DeskKit to Finish Allowing Access", #selector(restart(_:))))
        }
        if settings.windowPickerEnabled && !Permissions.screenRecording {
            access.append(item("Show Window Previews (Needs \(Permissions.screenRecordingName))…", #selector(allowScreenRecording(_:))))
        }
        if !access.isEmpty {
            menu.addItem(.separator())
            access.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        addToggle(to: menu, "Open at Login", #selector(toggleOpenAtLogin(_:)), LoginItem.isEnabled)
        addToggle(to: menu, "Show in Menu Bar", #selector(toggleMenuBarIcon(_:)), settings.showInMenuBar)
        menu.addItem(.separator())
        menu.addItem(item("About DeskKit", #selector(showAbout(_:))))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates(_:))))
        let quit = NSMenuItem(title: "Quit DeskKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func makeDockOptions() -> NSMenu {
        let menu = NSMenu()
        let settings = Settings.shared
        let modes: [(String, HideMode)] = [
            ("Hide When the Dock Hides", .sameAsDock),
            ("Never Hide", .never),
            ("Hide When a Window Covers It", .whenCovered),
            ("Always Hide", .always),
        ]
        for (title, value) in modes {
            let mode = item(title, #selector(chooseHideMode(_:)))
            mode.tag = value.rawValue
            mode.state = settings.hideMode == value ? .on : .off
            menu.addItem(mode)
        }
        menu.addItem(.separator())
        addToggle(to: menu, "Also Show on the Dock’s Display", #selector(toggleShowOnDockDisplay(_:)), settings.showOnDockDisplay)
        addToggle(to: menu, needingAccess("Keep Windows Clear of the Dock", settings.keepWindowsClear),
                  #selector(toggleKeepWindowsClear(_:)), settings.keepWindowsClear)
        return menu
    }

    /// A tool's title, noting when it's turned on but can't work yet.
    private func needingAccess(_ title: String, _ on: Bool) -> String {
        on && !hasAccessibility ? "\(title) (Needs Access)" : title
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func addToggle(to menu: NSMenu, _ title: String, _ action: Selector, _ on: Bool) {
        let toggle = item(title, action)
        toggle.state = on ? .on : .off
        menu.addItem(toggle)
    }

    // MARK: Actions

    @objc private func toggleDock(_ sender: NSMenuItem) {
        Settings.shared.dockEnabled.toggle()
        updateTools()
        // Without the Docks and the menu bar icon there'd be no way back to this menu.
        if !Settings.shared.dockEnabled && !Settings.shared.showInMenuBar { showMenuBarIcon() }
    }

    @objc private func toggleWindowPicker(_ sender: NSMenuItem) {
        Settings.shared.windowPickerEnabled.toggle()
        turnedOnTool(Settings.shared.windowPickerEnabled)
    }

    @objc private func toggleReverseMouseWheel(_ sender: NSMenuItem) {
        Settings.shared.reverseMouseWheel.toggle()
        turnedOnTool(Settings.shared.reverseMouseWheel)
    }

    @objc private func toggleKeepWindowsClear(_ sender: NSMenuItem) {
        Settings.shared.keepWindowsClear.toggle()
        turnedOnTool(Settings.shared.keepWindowsClear)
    }

    /// After a tool that needs Accessibility is switched: start or stop it, and ask for access if it's missing.
    private func turnedOnTool(_ on: Bool) {
        updateTools()
        if on && !hasAccessibility { Permissions.requestAccessibility() }
    }

    @objc private func allowAccessibility(_ sender: NSMenuItem) {
        Permissions.requestAccessibility()
    }

    @objc private func allowScreenRecording(_ sender: NSMenuItem) {
        Permissions.requestScreenRecording(thenOpenSettings: true)
    }

    @objc private func restart(_ sender: NSMenuItem) {
        relaunch()
    }

    @objc private func chooseHideMode(_ sender: NSMenuItem) {
        Settings.shared.hideMode = HideMode(rawValue: sender.tag) ?? .sameAsDock
        bars?.hideModeChanged()
    }

    @objc private func toggleShowOnDockDisplay(_ sender: NSMenuItem) {
        Settings.shared.showOnDockDisplay.toggle()
        bars?.showOnDockDisplayChanged()
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func toggleMenuBarIcon(_ sender: NSMenuItem) {
        Settings.shared.showInMenuBar.toggle()
        updateStatusItem()
        if !Settings.shared.showInMenuBar && !Settings.shared.didExplainHiddenMenuBarIcon {
            Settings.shared.didExplainHiddenMenuBarIcon = true
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The DeskKit icon is hidden"
            alert.informativeText = "To get this menu back, right-click an empty part of one of DeskKit's Docks, or open DeskKit again from your Applications folder."
            alert.runModal()
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updater.check(userInitiated: true)
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let page = "https://github.com/christopherquenneville/DeskKit"
        let credits = NSAttributedString(string: page, attributes: [.link: page, .font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
