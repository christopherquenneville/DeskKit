import AppKit

// Self-tests for the parts of DeskKit that need no permissions. Run them with Tests/run.sh.

var failures = 0

func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

MainActor.assumeIsolated {
    // MARK: Mouse wheel reversal

    let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: -1, wheel3: 0)!
    let trackpad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: -10, wheel3: 0)!
    check("a line scroll counts as a mouse wheel", ScrollFlipper.isMouseWheel(wheel))
    check("a pixel scroll counts as a trackpad", !ScrollFlipper.isMouseWheel(trackpad))

    let line = (wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1), wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    let fixed = wheel.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let point = wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    ScrollFlipper.flip(wheel)
    check("the vertical line delta is reversed", line.0 != 0 && wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -line.0)
    check("the horizontal line delta is reversed", line.1 != 0 && wheel.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -line.1)
    check("the fixed-point delta is reversed", wheel.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -fixed)
    check("the point delta is reversed", wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -point)

    // MARK: Window previews

    let wide = WindowPreviews.fit(CGSize(width: 1600, height: 900), into: CGSize(width: 200, height: 124))
    check("a wide window's preview fills the width", abs(wide.width - 200) < 0.01 && abs(wide.height - 112.5) < 0.01)
    let tall = WindowPreviews.fit(CGSize(width: 600, height: 1200), into: CGSize(width: 200, height: 124))
    check("a tall window's preview fills the height", abs(tall.height - 124) < 0.01 && abs(tall.width - 62) < 0.01)

    // MARK: Updates

    check("1.0.10 is newer than 1.0.9", Updater.isNewer("1.0.10", than: "1.0.9"))
    check("1.1 is newer than 1.0.5", Updater.isNewer("1.1", than: "1.0.5"))
    check("1.0 isn't newer than 1.0.0", !Updater.isNewer("1.0", than: "1.0.0"))
    check("an older version isn't newer", !Updater.isNewer("1.0.1", than: "1.0.2"))
    let answer = """
        {"tag_name": "v1.2.0", "body": "**Faster** previews", "draft": false,
         "html_url": "https://github.com/christopherquenneville/DeskKit/releases/tag/v1.2.0",
         "assets": [{"name": "Other.zip", "browser_download_url": "https://example.com/Other.zip"},
                    {"name": "DeskKit.zip", "browser_download_url": "https://github.com/christopherquenneville/DeskKit/releases/download/v1.2.0/DeskKit.zip"}]}
        """
    let release = try? Updater.release(from: Data(answer.utf8))
    check("a release's version comes from its tag", release?.version == "1.2.0")
    check("the download is the release's DeskKit.zip", release?.download.lastPathComponent == "DeskKit.zip" && release?.download.host == "github.com")
    check("release notes lose their Markdown marks", Updater.plainText(release?.notes ?? "") == "Faster previews")

    // MARK: Following the Dock's settings

    var pinned = DockPrefs()
    pinned.apps = [DockItem(kind: .app, label: "Mail")]
    var resized = DockPrefs()
    resized.tileSize = 64
    check("settings alone compare equal whatever the items", DockPrefs().withItems(of: pinned) == pinned)
    check("a new Dock size shows in the settings alone", resized.withItems(of: pinned) != pinned)
    check("the Dock's settings read without its items", DockPrefs.readSettings().apps.isEmpty)

    // MARK: Apps that hide the Dock

    // World of Warcraft in its borderless full-screen window asks for exactly this (seen on macOS 27).
    check("a game hiding the Dock and menu bar hides the copies", DockRequest([.hideDock, .hideMenuBar]) == .hide)
    check("an app asking for an auto-hiding Dock makes the copies auto-hide", DockRequest([.autoHideDock, .autoHideMenuBar]) == .autoHide)
    check("a full-screen app is left to the full-screen check", DockRequest([.fullScreen, .autoHideDock, .autoHideMenuBar]) == .none)
    check("an ordinary app leaves the copies as they are", DockRequest([]) == .none)

    // MARK: The Dock's size from the strip it reserves

    // Measured on macOS 27, a left Dock with 23 items on a 1152 pt-tall display: the strip each size
    // reserves, up to 45 pt, past which that Dock can't grow.
    let reserved: [(size: CGFloat, depth: CGFloat)] = [(28, 48), (30, 50), (34, 54), (36, 56), (37, 57), (38, 58), (39, 59),
                                                       (40, 60), (41, 61), (42, 62), (43, 63), (44, 64), (45, 65)]
    check("every measured Dock size is among those its strip allows",
          reserved.allSatisfy { BarMetrics.tiles(reserving: $0.depth).contains($0.size) })
    check("a full Dock set bigger than it can grow isn't taken to be its setting",
          ![46, 54, 63, 71, 83].contains { BarMetrics.tiles(reserving: 65).contains($0) })
    check("in-between sizes are among those their strip allows too", stride(from: 16.0, through: 128, by: 0.25).allSatisfy { size in
        BarMetrics.tiles(reserving: (CGFloat(size) + 20).rounded(.down)).contains(CGFloat(size))
    })

    // MARK: Magnification on a Dock that fills its screen

    // A left Dock on a 900 pt screen with a 30 pt menu bar, full enough that magnifying it can't fit.
    let height: CGFloat = 900
    let visible: ClosedRange<CGFloat> = 30...height
    var tiles = (0..<21).map { Tile(id: "app\($0)", kind: .app) }
    tiles.append(Tile(id: "separator", kind: .separator))
    tiles.append(Tile(id: "trash", kind: .trash))
    let tile = (visible.upperBound - visible.lowerBound - 8) / BarMetrics(tile: 1).length(of: tiles)
    let bar = BarView(frame: NSRect(x: 0, y: 0, width: 130, height: height))
    bar.configure(tiles: tiles, icons: [:], metrics: BarMetrics(tile: tile), orientation: .left, maxScale: 73 / tile,
                  center: (visible.lowerBound + visible.upperBound) / 2, visibleRange: visible, prefs: DockPrefs())

    /// Hovers the slot's centre (as laid out at rest), lets magnification settle, and returns the layout.
    @MainActor func magnified(over index: Int) -> BarLayout {
        bar.pointerMoved(to: nil)
        for _ in 0..<60 { _ = bar.step(now: 0, dt: 1.0 / 60) }
        let u = bar.layout.slots[index].center
        bar.pointerMoved(to: NSPoint(x: 20, y: height - u))
        for _ in 0..<60 { _ = bar.step(now: 0, dt: 1.0 / 60) }
        return bar.layout
    }

    let atEnd = magnified(over: tiles.count - 1)
    check("magnifying the Trash keeps the whole Trash on screen", atEnd.end <= visible.upperBound + 0.5)
    check("…and the bar grows toward the other end", atEnd.start < visible.lowerBound)
    let atStart = magnified(over: 0)
    check("magnifying the first app keeps it below the menu bar", atStart.start >= visible.lowerBound - 0.5)
    check("…and the bar grows toward the Trash", atStart.end > visible.upperBound)
    let middle = magnified(over: tiles.count / 2)
    check("magnifying the middle shares the overflow between both ends",
          middle.start < visible.lowerBound && middle.end > visible.upperBound)

    // MARK: System stats

    check("SMC names become codes and back", SMC.code("Tp01") == 0x5470_3031 && SMC.text(0x5470_3031) == "Tp01")
    let float = withUnsafeBytes(of: Float(64.5).bitPattern.littleEndian) { Array($0) }
    check("an Apple silicon sensor's float is read", SMC.decode(float, type: SMC.code("flt ")) == 64.5)
    check("an Intel sensor's sp78 is read", SMC.decode([0x40, 0x80], type: SMC.code("sp78")) == 64.5)
    check("a negative sp78 is read", SMC.decode([0xFF, 0x00], type: SMC.code("sp78")) == -1)
    check("the SMC's integers are big-endian", SMC.decode([0, 0, 0x0F, 0x1A], type: SMC.code("ui32")) == 3866)
    check("an unknown type isn't guessed at", SMC.decode([1, 2], type: SMC.code("ch8*")) == nil)
    check("unread and disconnected sensors are left out of the average", TemperatureSensors.average([64, 66, 0, -9201]) == 65)
    check("no readable sensor means no temperature", TemperatureSensors.average([0, 200]) == nil)
    let thinned = TemperatureSensors.spread(Array(0..<84), limit: 24)
    check("a long sensor list is thinned evenly", thinned.count == 24 && thinned.first == 0 && (thinned.last ?? 0) >= 80)
    check("a short sensor list is kept whole", TemperatureSensors.spread([1, 2, 3], limit: 24) == [1, 2, 3])

    let earlier = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
    check("CPU use is the busy share of the ticks since the last reading",
          CPUTicks(user: 160, system: 70, idle: 1770, nice: 0).usage(since: earlier) == 0.08)
    let wrapped = CPUTicks(user: 10, system: 0, idle: 40, nice: 0).usage(since: CPUTicks(user: .max - 9, system: 0, idle: .max - 39, nice: 0))
    check("CPU use survives the tick counters wrapping around", wrapped == 0.2)
    check("no ticks since the last reading means no CPU use", earlier.usage(since: earlier) == nil)

    check("memory used counts app, wired and compressed memory, as Activity Monitor does",
          SystemSnapshot.memoryUsed(anonymous: 1000, purgeable: 100, wired: 300, compressed: 200, pageSize: 16384) == 1400 * 16384)
    check("more purgeable pages than app pages don't go below zero",
          SystemSnapshot.memoryUsed(anonymous: 10, purgeable: 50, wired: 0, compressed: 0, pageSize: 4096) == 0)
    check("the kernel's memory pressure levels are read",
          MemoryPressure(level: 1) == .normal && MemoryPressure(level: 2) == .warning && MemoryPressure(level: 4) == .critical)
    check("memory pressure is told in Activity Monitor's terms",
          MemoryPressure.normal.summary == "Normal" && MemoryPressure.warning.summary.hasPrefix("High")
              && MemoryPressure.critical.summary.hasPrefix("Critical"))

    check("heavy thermal pressure counts as throttling", ThermalPressure(rawValue: 2) == .heavy && ThermalPressure.heavy.throttling.hasPrefix("Yes"))
    check("nominal thermal pressure isn't throttling", ThermalPressure.nominal.throttling == "None")
    check("ProcessInfo's fair state is read as moderate pressure", ThermalPressure(ProcessInfo.ThermalState.fair) == .moderate)

    check("the GPU's busy figure is read as a share", SystemMonitor.gpuUsage().map { (0...1).contains($0) } ?? true)
    check("shares show as whole percentages", StatsFormat.percent(0.234) == "23%" && StatsFormat.percent(1.2) == "100%")
    check("memory shows in gigabytes", StatsFormat.gigabytes(36 << 30) == "36 GB")
    check("a Mac without sensors says so", StatsFormat.temperatures(cpu: nil, gpu: nil, searched: true) == "Not available")
    let stats = StatsView()
    check("the stats fit in a menu", stats.frame.width > 200 && stats.frame.width < 420 && stats.frame.height > 50)

    // MARK: The Dock's icon menus

    let dockEntries: [DockMenuMirror.Entry] = [
        .init(title: "Front window", mark: "✓"),
        .init(title: "Minimized window", mark: "◆"),
        .init(title: "", enabled: false),
        .init(title: "Options", submenu: [.init(title: "Keep in Dock", mark: "✓"), .init(title: "Open at Login")]),
        .init(title: "Hide"),
        .init(title: "Hide Others", optionAlternate: true),
    ]
    let mirrored = DockMenuMirror.menu(from: dockEntries, for: Tile(id: "app", kind: .app))
    check("the Dock's menu is copied item for item", mirrored.items.count == 6 && mirrored.items[2].isSeparatorItem
              && mirrored.items[3].submenu?.items.map(\.title) == ["Keep in Dock", "Open at Login"])
    check("the front window is checked and a minimized one marked with a diamond",
          mirrored.items[0].state == .on && mirrored.items[1].onStateImage?.accessibilityDescription == "◆")
    check("Option shows Hide Others in place of Hide", mirrored.items[5].isAlternate && mirrored.items[5].keyEquivalentModifierMask == .option)
    check("an item in a submenu remembers where it is in the Dock's menu",
          (mirrored.items[3].submenu?.items[1].representedObject as? DockMenuChoice)?.path
              == [.init(index: 3, title: "Options"), .init(index: 1, title: "Open at Login")])

    // MARK: Built-in display

    let builtIn: CGDirectDisplayID = 1
    @MainActor func builtInAction(wanted: Bool = true, lidOpen: Bool = true, on: Bool, monitors: Bool, ours: Bool = false) -> BuiltInDisplay.Action {
        BuiltInDisplay.action(wanted: wanted, lidOpen: lidOpen, builtIn: builtIn, builtInOn: on, monitors: monitors, turnedOffByDeskKit: ours)
    }
    check("with the lid open and a monitor on, the built-in display goes off", builtInAction(on: true, monitors: true) == .turnOff(builtIn))
    check("it stays off while a monitor is on", builtInAction(on: false, monitors: true, ours: true) == BuiltInDisplay.Action.none)
    check("it comes back when the last monitor goes", builtInAction(on: false, monitors: false, ours: true) == .turnOn(builtIn))
    check("it comes back without a monitor even if DeskKit lost track of turning it off",
          builtInAction(on: false, monitors: false, ours: false) == .turnOn(builtIn))
    check("it comes back when the setting is turned off", builtInAction(wanted: false, on: false, monitors: true, ours: true) == .turnOn(builtIn))
    check("another app turning it off is left alone while a monitor is on",
          builtInAction(wanted: false, on: false, monitors: true, ours: false) == BuiltInDisplay.Action.none)
    check("with the lid closed nothing changes", builtInAction(lidOpen: false, on: false, monitors: false, ours: true) == BuiltInDisplay.Action.none)
    check("without a monitor the built-in display stays on", builtInAction(on: true, monitors: false) == BuiltInDisplay.Action.none)
    check("a display that reports no monitor (a virtual one) isn't a monitor", !BuiltInDisplay.isMonitor(9999) && !BuiltInDisplay.isReal(9999))

    // MARK: Stray pointer moves

    var flood = StrayMoveGuard.Counter()
    let floodCaught = (0..<StrayMoveGuard.limit).map { flood.add(at: 100 + Double($0) * 0.001) }
    check("a stream of moves away from DeskKit's windows is caught", floodCaught.last == true && floodCaught.dropLast().allSatisfy { !$0 })
    var trickle = StrayMoveGuard.Counter()
    check("the odd stray move over a long time isn't", !(0..<1000).contains { trickle.add(at: Double($0) * 0.1) })
}

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
