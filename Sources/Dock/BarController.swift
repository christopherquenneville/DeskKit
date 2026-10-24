import AppKit

/// A borderless panel that never becomes key or main, so clicking it never activates DeskKit.
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would nudge the panel off the menu bar's strip; the bar is placed exactly on purpose.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One bar on one display: its panel, background and icon view, and whether it is shown.
@MainActor
final class BarController: NSObject {
    enum Transition { case fade, slide }

    let displayID: CGDirectDisplayID
    unowned let manager: BarManager
    private(set) var screen: NSScreen
    /// The screen's visible frame without its menu bar (see `NSScreen.usableFrame`), as of the last configure.
    private var visibleFrame = NSRect.zero
    let panel: BarPanel
    let view: BarView
    private let background: BarBackground
    private var prefs = DockPrefs()

    var isDockDisplay = false
    var covered = false
    private var revealed = false
    private var revealTimer: Timer?
    private var lingerTimer: Timer?

    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var slide: CGFloat = 1
    private var slideTarget: CGFloat = 1
    private var transitionDuration: CGFloat = 0.25
    private var animationTimer: Timer?
    private var lastFrame: CFTimeInterval = 0

    init(screen: NSScreen, manager: BarManager) {
        self.screen = screen
        self.displayID = screen.displayID
        self.manager = manager
        let frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        panel = BarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background = BarBackground(cornerRadius: 12)
        view = BarView(frame: frame)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = background.wantsWindowShadow
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // No .fullScreenAuxiliary: like the Dock, bars stay out of full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.alphaValue = 0

        let content = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]
        content.addSubview(background.view)
        content.addSubview(view)
        panel.contentView = content
        view.controller = self
    }

    func close() {
        animationTimer?.invalidate()
        revealTimer?.invalidate()
        lingerTimer?.invalidate()
        manager.label.hide(owner: displayID)
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Placement

    private var showsOnDockDisplay: Bool { isDockDisplay && Settings.shared.showOnDockDisplay }

    /// Sizes the panel tightly around the bar, plus room for magnified and bouncing icons.
    func configure(screen: NSScreen, tiles: [Tile], icons: [String: NSImage], prefs: DockPrefs) {
        self.screen = screen
        self.prefs = prefs
        visibleFrame = screen.usableFrame
        let orientation = prefs.orientation
        let vertical = orientation != .bottom
        // Beside the Dock on its own display; against the screen edge everywhere else.
        let edges = showsOnDockDisplay ? visibleFrame : screen.frame
        let usable = vertical ? visibleFrame.height : visibleFrame.width

        // Shrink the icons, as the Dock does, when the bar doesn't fit along the screen.
        var tile = prefs.tileSize
        let lengthPerPoint = BarMetrics(tile: 1).length(of: tiles)
        if lengthPerPoint * tile > usable - 8 { tile = max(16, (usable - 8) / lengthPerPoint) }
        let metrics = BarMetrics(tile: tile)
        let maxScale = prefs.magnification ? max(1, prefs.largeSize / tile) : 1

        // Centred in the visible area like the Dock, with the panel kept on its own screen so a
        // magnified end never spills onto a neighbouring display.
        let spare = maxScale > 1 ? (maxScale - 1) * metrics.magnifyRadius + metrics.pitch : 0
        let center = vertical ? visibleFrame.midY : visibleFrame.midX
        let lower = vertical ? screen.frame.minY : screen.frame.minX
        let upper = vertical ? screen.frame.maxY : screen.frame.maxX
        let along = min(metrics.length(of: tiles) + 2 * spare, upper - lower).rounded()
        let start = min(max((center - along / 2).rounded(), lower), upper - along)
        let across = (BarMetrics.edgeMargin + metrics.sidePadding + tile * maxScale * 1.5 + 8).rounded(.up)
        // In the view, `u` runs left to right for a bottom bar and top to bottom for a side bar.
        let frame: NSRect
        let barCenter: CGFloat
        let visibleRange: ClosedRange<CGFloat>
        switch orientation {
        case .bottom:
            frame = NSRect(x: start, y: edges.minY, width: along, height: across)
            barCenter = center - start
            visibleRange = (visibleFrame.minX - start)...(visibleFrame.maxX - start)
        case .left, .right:
            let x = orientation == .left ? edges.minX : edges.maxX - across
            frame = NSRect(x: x, y: start, width: across, height: along)
            barCenter = start + along - center
            visibleRange = (start + along - visibleFrame.maxY)...(start + along - visibleFrame.minY)
        }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        background.cornerRadius = metrics.cornerRadius
        view.configure(tiles: tiles, icons: icons, metrics: metrics, orientation: orientation, maxScale: maxScale,
                       center: barCenter, visibleRange: visibleRange, prefs: prefs)
        applySlide()
    }

    /// The resting bar in screen coordinates.
    var restingFrameOnScreen: NSRect {
        view.restingBarRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// The strip windows should stay out of, for as long as this bar stays on screen: as deep as the
    /// Dock's own reserved space would be (the bar plus its gap from the edge).
    var keepClearStrip: WindowKeeper.Strip? {
        guard alphaTarget > 0, effectiveHideMode == .never, !(isDockDisplay && !Settings.shared.showOnDockDisplay) else {
            return nil
        }
        let edges = showsOnDockDisplay ? visibleFrame : screen.frame
        return WindowKeeper.Strip(orientation: prefs.orientation, edges: edges.inCGCoordinates,
                                  visible: visibleFrame.inCGCoordinates,
                                  reserve: BarMetrics.edgeMargin + view.metrics.thickness)
    }

    func barLayoutChanged() {
        background.setFrame(view.barRect)
        if panel.hasShadow && panel.isVisible { panel.invalidateShadow() }
        updateLabel()
    }

    // MARK: Showing and hiding

    private var effectiveHideMode: HideMode {
        let mode = Settings.shared.hideMode
        return mode == .sameAsDock ? (prefs.autohide ? .always : .never) : mode
    }

    private var autoHides: Bool {
        if isDockDisplay && !Settings.shared.showOnDockDisplay { return false }
        return effectiveHideMode == .whenCovered || effectiveHideMode == .always
    }

    private var shouldShow: Bool {
        if isDockDisplay && !Settings.shared.showOnDockDisplay { return false }
        switch effectiveHideMode {
        case .never, .sameAsDock: return true
        case .whenCovered: return !covered || revealed
        case .always: return revealed
        }
    }

    /// Fades (the Dock arriving or leaving) or slides (auto-hiding) the bar toward its target state.
    func updateVisibility(_ transition: Transition) {
        let show = shouldShow
        let target: CGFloat = show ? 1 : 0
        if target == alphaTarget && (!show || slideTarget == 1) { return }
        alphaTarget = target
        switch transition {
        case .slide:
            if show && alpha == 0 { slide = 0 }
            slideTarget = target
            transitionDuration = 0.25 * CGFloat(prefs.autohideTimeModifier)
        case .fade:
            if show { slide = 1 }
            slideTarget = slide
            transitionDuration = 0.25
        }
        applySlide()
        if show && !panel.isVisible { panel.orderFrontRegardless() }
        if !show {
            view.pointerMoved(to: nil)
            manager.label.hide(owner: displayID)
            if alpha == 0 { panel.orderOut(nil) }
        }
        startAnimating()
    }

    func hideModeChanged() {
        revealTimer?.invalidate()
        revealTimer = nil
        lingerTimer?.invalidate()
        lingerTimer = nil
        revealed = view.isHovering
        updateVisibility(.slide)
        pointerMoved(to: NSEvent.mouseLocation)
    }

    private func setRevealed(_ value: Bool) {
        revealTimer?.invalidate()
        revealTimer = nil
        lingerTimer?.invalidate()
        lingerTimer = nil
        guard revealed != value else { return }
        revealed = value
        updateVisibility(.slide)
    }

    @objc private func revealDelayEnded(_ timer: Timer) {
        revealTimer = nil
        setRevealed(true)
    }

    @objc private func lingerEnded(_ timer: Timer) {
        lingerTimer = nil
        if !view.isHovering && !view.menuOpen && !view.isPressing { setRevealed(false) }
    }

    private func oneShot(_ delay: TimeInterval, _ selector: Selector) -> Timer {
        let timer = Timer(timeInterval: delay, target: self, selector: selector, userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Pointer

    /// Called for every pointer move anywhere, with the pointer in screen coordinates.
    func pointerMoved(to point: NSPoint) {
        let f = screen.frame
        let onScreen = point.x >= f.minX && point.x <= f.maxX && point.y >= f.minY && point.y <= f.maxY
        let atEdge: Bool
        switch prefs.orientation {
        case .bottom: atEdge = onScreen && point.y <= f.minY + 1
        case .left: atEdge = onScreen && point.x <= f.minX + 1
        case .right: atEdge = onScreen && point.x >= f.maxX - 1
        }
        if autoHides {
            if atEdge && !revealed && revealTimer == nil {
                let delay = Settings.shared.hideMode == .sameAsDock ? prefs.autohideDelay : 0
                if delay > 0 { revealTimer = oneShot(delay, #selector(revealDelayEnded(_:))) } else { setRevealed(true) }
            } else if !atEdge, let timer = revealTimer {
                timer.invalidate()
                revealTimer = nil
            }
        }

        // After any reveal above, so a pointer resting on the edge magnifies straight away.
        let usable = onScreen && alphaTarget > 0
        let over = view.pointerMoved(to: usable ? NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY) : nil)
        guard autoHides, revealed else { return }
        if over || atEdge || view.menuOpen || view.isPressing {
            lingerTimer?.invalidate()
            lingerTimer = nil
        } else if lingerTimer == nil {
            lingerTimer = oneShot(0.4, #selector(lingerEnded(_:)))
        }
    }

    func hoverChanged() {
        updateLabel()
    }

    func menuWillOpen() {
        manager.label.hide(owner: displayID)
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    func menuDidClose() {
        manager.pointerMoved()
    }

    private func updateLabel() {
        guard alphaTarget > 0, let (tile, anchor) = view.hoveredLabelAnchor() else {
            manager.label.hide(owner: displayID)
            return
        }
        let point = NSPoint(x: panel.frame.minX + anchor.x, y: panel.frame.minY + anchor.y)
        manager.label.show(tile.label, at: point, orientation: prefs.orientation, owner: displayID)
    }

    // MARK: Animation

    /// Runs a 60 Hz timer only while something is moving.
    func startAnimating() {
        guard animationTimer == nil else { return }
        lastFrame = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(animate(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func animate(_ timer: Timer) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 1.0 / 20.0)
        lastFrame = now
        var running = view.step(now: now, dt: dt)
        let step = transitionDuration > 0 ? CGFloat(dt) / transitionDuration : 1
        if alpha != alphaTarget {
            alpha = approach(alpha, alphaTarget, step)
            panel.alphaValue = alpha
            if alpha == 0 && alphaTarget == 0 { panel.orderOut(nil) }
            running = running || alpha != alphaTarget
        }
        if slide != slideTarget {
            slide = approach(slide, slideTarget, step)
            applySlide()
            running = running || slide != slideTarget
        }
        if !running {
            timer.invalidate()
            animationTimer = nil
        }
    }

    private func applySlide() {
        let eased = 1 - pow(1 - slide, 3)
        view.slideOffset = -(1 - eased) * (BarMetrics.edgeMargin + view.metrics.thickness + 6)
    }
}
