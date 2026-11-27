import AppKit

/// The real Dock's menu for one of its icons, so a Dock copy can show the same one: the app's
/// windows, the app's own items (Terminal's New Window, say, which apps hand only to the Dock),
/// Options, Show All Windows, Hide and Quit. The Dock builds that menu when asked through
/// Accessibility: DeskKit asks, reads it and closes it straight away (it's on screen for a frame or
/// so), then shows the same menu beside its own icon. Choosing an item opens the Dock's menu again
/// and picks the same item there, so it does exactly what the Dock would.
@MainActor
enum DockMenuMirror {
    struct Entry: Equatable {
        var title: String
        var enabled = true
        /// The Dock's mark: ✓ for an app's front window, • for one with unsaved changes, ◆ for a minimized one.
        var mark = ""
        /// Shown instead of the item before it while Option is held (Hide Others, Force Quit).
        var optionAlternate = false
        var submenu: [Entry]?

        var isSeparator: Bool { title.isEmpty && submenu == nil }
    }

    /// Where an item sits in the Dock's menu: its index and title at each level.
    struct Step: Equatable {
        let index: Int
        let title: String
    }

    /// How long to wait for the Dock to build a menu (it takes about a tenth of a second).
    static let wait: CFTimeInterval = 0.6

    /// The Dock's menu for `tile`'s icon, or nil when it can't be read: no Accessibility, no such icon
    /// in the Dock, or no menu in time.
    static func entries(for tile: Tile) -> [Entry]? {
        guard Permissions.accessibilityAPIReady, let item = dockItem(for: tile), let menu = openMenu(of: item) else { return nil }
        let entries = read(menu)
        cancel(menu)
        return entries.contains { !$0.isSeparator } ? entries : nil
    }

    /// Picks the item at `path` in the Dock's menu for `tile`. Each step is matched by title, in
    /// case the menu changed since it was read (a window opened or closed).
    static func choose(_ path: [Step], for tile: Tile) {
        guard let item = dockItem(for: tile), let menu = openMenu(of: item) else { return }
        var level = menu
        for (depth, step) in path.enumerated() {
            let items = menuItems(of: level)
            let element = items.indices.contains(step.index) && title(of: items[step.index]) == step.title
                ? items[step.index] : items.first { title(of: $0) == step.title }
            guard let element else {
                appLog.info("The Dock's menu no longer has \(step.title, privacy: .public)")
                return cancel(menu)
            }
            if depth == path.count - 1 {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            } else if let submenu = submenu(of: element) {
                level = submenu
            } else {
                return cancel(menu)
            }
        }
    }

    /// The menu to show for `entries`, its items choosing the same ones in the Dock's menu.
    static func menu(from entries: [Entry], for tile: Tile, path: [Step] = []) -> NSMenu {
        let result = NSMenu()
        result.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                result.addItem(.separator())
                continue
            }
            let step = Step(index: index, title: entry.title)
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            if let submenu = entry.submenu {
                item.submenu = menu(from: submenu, for: tile, path: path + [step])
            } else {
                let choice = DockMenuChoice(tile: tile, path: path + [step])
                item.target = choice
                item.action = #selector(DockMenuChoice.choose(_:))
                item.representedObject = choice
            }
            if !entry.mark.isEmpty {
                item.state = .on
                if let symbol = markSymbol(entry.mark) {
                    item.onStateImage = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.mark)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .regular))
                }
            }
            if entry.optionAlternate {
                item.keyEquivalentModifierMask = .option
                item.isAlternate = true
            }
            result.addItem(item)
        }
        return result
    }

    /// A ✓ is the menu's own check mark; the Dock's other marks are drawn as small symbols.
    private static func markSymbol(_ mark: String) -> String? {
        switch mark {
        case "•", "●": return "circle.fill"
        case "◆", "♦": return "diamond.fill"
        default: return nil
        }
    }

    // MARK: The Dock through Accessibility

    private static func dockItem(for tile: Tile) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let items = children(of: app).filter { role(of: $0) == kAXListRole }.flatMap { children(of: $0) }
        if tile.kind == .trash {
            return items.first { AX.attribute($0, kAXSubroleAttribute) as? String == "AXTrashDockItem" }
        }
        if let url = tile.url {
            let path = normalizedPath(url)
            if let item = items.first(where: { (AX.attribute($0, kAXURLAttribute) as? URL).map(normalizedPath) == path }) { return item }
        }
        return tile.label.isEmpty ? nil : items.first { title(of: $0) == tile.label }
    }

    /// Asks the Dock to show `item`'s menu and waits for it to appear.
    private static func openMenu(of item: AXUIElement) -> AXUIElement? {
        guard AXUIElementPerformAction(item, "AXShowMenu" as CFString) == .success else { return nil }
        let deadline = CACurrentMediaTime() + wait
        repeat {
            if let menu = submenu(of: item) { return menu }
            usleep(2000)
        } while CACurrentMediaTime() < deadline
        appLog.info("The Dock didn't show its menu in time")
        return nil
    }

    private static func read(_ menu: AXUIElement) -> [Entry] {
        menuItems(of: menu).map { element in
            var entry = Entry(title: title(of: element))
            entry.enabled = AX.attribute(element, kAXEnabledAttribute) as? Bool ?? true
            entry.mark = AX.attribute(element, kAXMenuItemMarkCharAttribute) as? String ?? ""
            let modifiers = (AX.attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
            entry.optionAlternate = UInt32(modifiers) & AXMenuItemModifiers.option.rawValue != 0
            entry.submenu = submenu(of: element).map(read)
            return entry
        }
    }

    private static func cancel(_ menu: AXUIElement) {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func menuItems(of menu: AXUIElement) -> [AXUIElement] {
        children(of: menu).filter { role(of: $0) == kAXMenuItemRole }
    }

    private static func submenu(of element: AXUIElement) -> AXUIElement? {
        children(of: element).first { role(of: $0) == kAXMenuRole }
    }

    private static func role(of element: AXUIElement) -> String? {
        AX.attribute(element, kAXRoleAttribute) as? String
    }

    private static func title(of element: AXUIElement) -> String {
        AX.attribute(element, kAXTitleAttribute) as? String ?? ""
    }
}

/// What a mirrored menu item does when chosen. The item keeps it alive (as its represented object).
@MainActor
final class DockMenuChoice: NSObject {
    let tile: Tile
    let path: [DockMenuMirror.Step]

    init(tile: Tile, path: [DockMenuMirror.Step]) {
        self.tile = tile
        self.path = path
    }

    @objc func choose(_ sender: NSMenuItem) {
        DockMenuMirror.choose(path, for: tile)
    }
}
