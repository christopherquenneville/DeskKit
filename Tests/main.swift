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
}

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
