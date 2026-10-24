import AppKit

/// Sizes measured from the macOS 26/27 Dock (at a 42 pt tile size) and scaled with the tile size.
struct BarMetrics {
    var tile: CGFloat
    /// Gap between the screen edge and the bar.
    static let edgeMargin: CGFloat = 4

    var gap: CGFloat { tile * 2 / 42 }
    var pitch: CGFloat { tile + gap }
    /// From the end of the bar to its first slot.
    var endPadding: CGFloat { tile * 0.05 }
    /// From the bar's long edges to the icons.
    var sidePadding: CGFloat { tile * 8 / 42 }
    var thickness: CGFloat { tile + 2 * sidePadding }
    var cornerRadius: CGFloat { thickness * 0.22 }
    var dotDiameter: CGFloat { max(3, tile * 4 / 42) }
    /// From the bar's screen-side edge to the centre of a running-app dot.
    var dotOffset: CGFloat { tile * 6.75 / 42 }
    /// How far magnification reaches on each side of the pointer.
    var magnifyRadius: CGFloat { pitch * 3.6 }

    func slotLength(_ kind: TileKind) -> CGFloat {
        switch kind {
        case .separator: return tile / 2
        case .smallSpacer: return pitch / 2
        default: return pitch
        }
    }

    func length(of tiles: [Tile]) -> CGFloat {
        tiles.reduce(2 * endPadding) { $0 + slotLength($1.kind) }
    }
}

struct Slot {
    var center: CGFloat
    var length: CGFloat
    var scale: CGFloat
}

struct BarLayout {
    var slots: [Slot]
    var start: CGFloat
    var end: CGFloat
}

/// Draws a whole bar (icons, dots, separators) in one view and handles its clicks and drops.
///
/// Geometry is worked out in bar coordinates: `u` runs along the bar from its first tile,
/// and `v` runs away from the screen edge the bar is attached to. `viewPoint(u:v:)` maps
/// them onto the view for a bottom, left or right Dock.
@MainActor
final class BarView: NSView {
    weak var controller: BarController?

    private(set) var tiles: [Tile] = []
    private var icons: [String: NSImage] = [:]
    private(set) var metrics = BarMetrics(tile: 48)
    private(set) var orientation: DockOrientation = .bottom
    private var maxScale: CGFloat = 1
    /// Where the bar's centre sits along it, in `u`.
    private var center: CGFloat = 0
    /// The part of the screen (in `u`) a magnified bar may grow into: not under the menu bar.
    private var visibleRange: ClosedRange<CGFloat> = -CGFloat.greatestFiniteMagnitude...CGFloat.greatestFiniteMagnitude
    private var showIndicators = true
    private var dimHiddenApps = false

    /// Moves the content toward the screen edge while the bar slides in or out (0 when resting).
    var slideOffset: CGFloat = 0 {
        didSet { if slideOffset != oldValue { layoutChanged() } }
    }

    private(set) var isHovering = false
    private(set) var menuOpen = false
    private var pointerU: CGFloat = 0
    private var magnification: CGFloat = 0
    private var pressedID: String?
    private var pressInside = false
    private var dropID: String?
    private var bounces: [String: Bounce] = [:]
    private var cachedLayout: BarLayout?
    /// Layout changes (from the pointer, magnification, sliding) are drawn on the controller's next
    /// frame, so a fast mouse doesn't cause a redraw per event.
    private var layoutPending = false
    private var hoveredSlot: Int?
    /// Each icon drawn once into a bitmap at its largest size, in the window's colours: drawing the
    /// NSImage itself picks a representation and converts colours on every frame, which made
    /// magnifying cost several times more.
    private var bitmaps: [String: (icon: NSImage, image: CGImage)] = [:]

    private struct Bounce {
        var start: CFTimeInterval
        var stopAt: CFTimeInterval?
    }
    private static let bouncePeriod: CFTimeInterval = 0.62
    private static let bounceLimit: CFTimeInterval = 30

    var isPressing: Bool { pressedID != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        registerForDraggedTypes([.fileURL])
        // The pointer is only reported while it's over the bar (where the hit fill is), never elsewhere.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderAgain()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderAgain()
    }

    func configure(tiles: [Tile], icons: [String: NSImage], metrics: BarMetrics, orientation: DockOrientation,
                   maxScale: CGFloat, center: CGFloat, visibleRange: ClosedRange<CGFloat>, prefs: DockPrefs) {
        self.tiles = tiles
        self.icons = icons
        bitmaps = bitmaps.filter { icons[$0.key] != nil }
        if metrics.tile * maxScale != self.metrics.tile * self.maxScale {
            bitmaps.removeAll()
            darkBitmaps.removeAll()
            badgeImages.removeAll()
        }
        self.metrics = metrics
        self.orientation = orientation
        self.maxScale = maxScale
        self.center = center
        self.visibleRange = visibleRange
        showIndicators = prefs.showIndicators
        dimHiddenApps = prefs.dimHiddenApps
        if let id = pressedID, !tiles.contains(where: { $0.id == id }) { pressedID = nil }
        if let id = dropID, !tiles.contains(where: { $0.id == id }) { dropID = nil }
        layoutChanged()
    }

    // MARK: Geometry

    private var iconBase: CGFloat { BarMetrics.edgeMargin + metrics.sidePadding + slideOffset }

    func viewPoint(u: CGFloat, v: CGFloat) -> NSPoint {
        switch orientation {
        case .bottom: return NSPoint(x: u, y: v)
        case .left: return NSPoint(x: v, y: bounds.height - u)
        case .right: return NSPoint(x: bounds.width - v, y: bounds.height - u)
        }
    }

    func viewRect(u0: CGFloat, u1: CGFloat, v0: CGFloat, v1: CGFloat) -> NSRect {
        let a = viewPoint(u: u0, v: v0), b = viewPoint(u: u1, v: v1)
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func barCoordinates(_ p: NSPoint) -> (u: CGFloat, v: CGFloat) {
        switch orientation {
        case .bottom: return (p.x, p.y)
        case .left: return (bounds.height - p.y, p.x)
        case .right: return (bounds.height - p.y, bounds.width - p.x)
        }
    }

    var layout: BarLayout {
        if let cachedLayout { return cachedLayout }
        let layout = computeLayout()
        cachedLayout = layout
        return layout
    }

    /// The bar's background as it is drawn right now (magnified, sliding).
    var barRect: NSRect {
        let layout = layout
        let v0 = BarMetrics.edgeMargin + slideOffset
        return viewRect(u0: layout.start, u1: layout.end, v0: v0, v1: v0 + metrics.thickness)
    }

    /// The bar's background at rest, used to decide whether a window covers it.
    var restingBarRect: NSRect {
        let length = metrics.length(of: tiles)
        let start = center - length / 2
        return viewRect(u0: start, u1: start + length,
                        v0: BarMetrics.edgeMargin, v1: BarMetrics.edgeMargin + metrics.thickness)
    }

    private func layoutChanged() {
        cachedLayout = nil
        layoutPending = true
        controller?.startAnimating()
    }

    /// Shows a pending layout change; returns whether there was one.
    func applyPendingLayout() -> Bool {
        guard layoutPending else { return false }
        layoutPending = false
        updateLayers()
        controller?.barLayoutChanged()
        return true
    }

    /// Slot starts and lengths with nothing magnified.
    private func restingSlots() -> (starts: [CGFloat], lengths: [CGFloat], start: CGFloat, total: CGFloat) {
        let m = metrics
        let lengths = tiles.map { m.slotLength($0.kind) }
        let total = lengths.reduce(2 * m.endPadding, +)
        let start = center - total / 2
        var starts: [CGFloat] = []
        var u = start + m.endPadding
        for length in lengths {
            starts.append(u)
            u += length
        }
        return (starts, lengths, start, total)
    }

    private func computeLayout() -> BarLayout {
        let m = metrics
        let (starts, lengths, start, total) = restingSlots()
        let amount = smoothstep(magnification)
        guard amount > 0, maxScale > 1, !tiles.isEmpty else {
            let slots = zip(starts, lengths).map { Slot(center: $0 + $1 / 2, length: $1, scale: 1) }
            return BarLayout(slots: slots, start: start, end: start + total)
        }

        // Cosine falloff around the pointer.
        let radius = m.magnifyRadius
        let scales = zip(starts, lengths).map { start, length -> CGFloat in
            let distance = abs(start + length / 2 - pointerU)
            guard distance < radius else { return 1 }
            return 1 + (maxScale - 1) * amount * (cos(.pi * distance / radius) + 1) / 2
        }
        let grown = zip(lengths, scales).map { $0 * $1 }

        // Keep the point under the pointer still: it stays at the same fraction of its slot.
        let k: Int
        let fraction: CGFloat
        if pointerU <= starts[0] {
            (k, fraction) = (0, 0)
        } else if pointerU >= starts[starts.count - 1] + lengths[lengths.count - 1] {
            (k, fraction) = (starts.count - 1, 1)
        } else {
            k = starts.lastIndex { $0 <= pointerU } ?? 0
            fraction = (pointerU - starts[k]) / lengths[k]
        }
        var grownStarts: [CGFloat] = []
        var position: CGFloat = 0
        for length in grown {
            grownStarts.append(position)
            position += length
        }
        var shift = (starts[k] + fraction * lengths[k]) - (grownStarts[k] + fraction * grown[k])
        // A bar that nearly fills the screen would grow past its ends; keep it on the visible part.
        let grownStart = grownStarts[0] + shift - m.endPadding
        let grownEnd = position + shift + m.endPadding
        let excess = (grownEnd - grownStart) - (visibleRange.upperBound - visibleRange.lowerBound)
        if excess <= 0 {
            if grownStart < visibleRange.lowerBound {
                shift += visibleRange.lowerBound - grownStart
            } else if grownEnd > visibleRange.upperBound {
                shift -= grownEnd - visibleRange.upperBound
            }
        } else {
            // Too long to fit: like the Dock, keep the end by the pointer on screen and let the far
            // end run off, sharing the overflow by where the pointer is between the end icons.
            let first = starts[0] + lengths[0] / 2
            let last = starts[starts.count - 1] + lengths[lengths.count - 1] / 2
            let along = last > first ? min(max((pointerU - first) / (last - first), 0), 1) : 0.5
            shift += visibleRange.lowerBound - excess * along - grownStart
        }
        let slots = grown.indices.map {
            Slot(center: grownStarts[$0] + shift + grown[$0] / 2, length: grown[$0], scale: scales[$0])
        }
        return BarLayout(slots: slots, start: grownStarts[0] + shift - m.endPadding,
                         end: position + shift + m.endPadding)
    }

    // MARK: Hit testing

    /// The slot under `u`: each slot reaches halfway to its neighbours, and the end slots to the bar's ends.
    private func slotIndex(atU u: CGFloat, in layout: BarLayout) -> Int? {
        guard !layout.slots.isEmpty, u >= layout.start, u <= layout.end else { return nil }
        var index = 0
        for i in 1..<layout.slots.count where u >= (layout.slots[i - 1].center + layout.slots[i].center) / 2 {
            index = i
        }
        return index
    }

    /// How far from the screen edge slot `i` reaches: the bar, or its icon when that is magnified past it.
    /// Measured at rest: sliding in or out is only a look, so the pointer that revealed the bar counts.
    private func reach(of i: Int, in layout: BarLayout) -> CGFloat {
        let barTop = BarMetrics.edgeMargin + metrics.thickness
        let iconTop = BarMetrics.edgeMargin + metrics.sidePadding + metrics.tile * layout.slots[i].scale + 2
        return max(barTop, iconTop)
    }

    /// The tile under a point in view coordinates. Slots run all the way to the screen edge.
    func tileIndex(at point: NSPoint) -> Int? {
        let (u, v) = barCoordinates(point)
        let layout = layout
        guard v >= -0.5, let i = slotIndex(atU: u, in: layout), v <= reach(of: i, in: layout) else { return nil }
        return i
    }

    // MARK: Pointer

    /// Feeds the pointer position in view coordinates (nil when it's elsewhere).
    /// Returns whether the pointer is over the bar.
    @discardableResult
    func pointerMoved(to point: NSPoint?) -> Bool {
        let index = point.flatMap { tileIndex(at: $0) }
        let inside = index != nil
        if inside, let point {
            let u = barCoordinates(point).u
            if u != pointerU {
                pointerU = u
                if magnification > 0 && maxScale > 1 { layoutChanged() }
            }
        }
        if inside != isHovering {
            isHovering = inside
            controller?.startAnimating()
        }
        if index != hoveredSlot {
            // The name label moves on the next frame, not on every pointer event.
            hoveredSlot = index
            layoutPending = true
            controller?.startAnimating()
        }
        return inside
    }

    /// The hovered tile and where its name label goes (just past the icon, in view coordinates).
    func hoveredLabelAnchor() -> (tile: Tile, point: NSPoint)? {
        let layout = layout
        guard isHovering, !menuOpen, let i = slotIndex(atU: pointerU, in: layout), tiles[i].isActionable else {
            return nil
        }
        let slot = layout.slots[i]
        return (tiles[i], viewPoint(u: slot.center, v: iconBase + metrics.tile * slot.scale + 7))
    }

    // MARK: Animation

    func startBounce(_ id: String) {
        if bounces[id] != nil {
            bounces[id]?.stopAt = nil
        } else {
            bounces[id] = Bounce(start: CACurrentMediaTime(), stopAt: nil)
        }
        controller?.startAnimating()
    }

    /// Lets the current bounce land, then stops.
    func stopBounce(_ id: String) {
        guard let bounce = bounces[id], bounce.stopAt == nil else { return }
        let cycles = max(1, ((CACurrentMediaTime() - bounce.start) / Self.bouncePeriod).rounded(.up))
        bounces[id]?.stopAt = bounce.start + cycles * Self.bouncePeriod
    }

    private func bounceLift(_ id: String, size: CGFloat, now: CFTimeInterval) -> CGFloat {
        guard let bounce = bounces[id] else { return 0 }
        let phase = CGFloat(((now - bounce.start) / Self.bouncePeriod).truncatingRemainder(dividingBy: 1))
        return 4 * phase * (1 - phase) * size * 0.5
    }

    /// Advances magnification and bounces. Returns whether anything is still moving.
    func step(now: CFTimeInterval, dt: CFTimeInterval) -> Bool {
        var running = false
        // Like the Dock, magnification settles back while a menu is open.
        let target: CGFloat = isHovering && !menuOpen && maxScale > 1 ? 1 : 0
        if magnification != target {
            let duration: CGFloat = target > magnification ? 0.12 : 0.2
            magnification = approach(magnification, target, CGFloat(dt) / duration)
            layoutChanged()
            running = running || magnification != target
        }
        if !bounces.isEmpty {
            for (id, bounce) in bounces {
                if let stop = bounce.stopAt, now >= stop {
                    bounces[id] = nil
                } else if now - bounce.start > Self.bounceLimit {
                    bounces[id] = nil
                }
            }
            layoutPending = true
            running = running || !bounces.isEmpty
        }
        return running
    }

    // MARK: Rendering

    /// The bar is made of Core Animation layers rather than drawn: each icon is a layer showing a
    /// bitmap made once, so magnifying, sliding and bouncing only move and resize layers, and the
    /// GPU does the scaling, as it does for the Dock.
    private struct TileLayers {
        let icon = CALayer()
        let badge = CALayer()
        let dot = CALayer()
        var image: CGImage?
        var badgeText: String?
    }

    private var tileLayers: [String: TileLayers] = [:]
    private var separatorLayers: [CALayer] = []
    /// The window server lets clicks through fully transparent pixels, so every slot's hit area (out
    /// to the screen edge, and up to a magnified icon's top) gets an invisible solid layer.
    private var hitLayers: [CALayer] = []
    private var darkBitmaps: [String: CGImage] = [:]
    private var badgeImages: [String: CGImage] = [:]

    /// Puts every layer where the layout says, without implicit animations (the bar animates itself).
    private func updateLayers() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let layout = layout
        let m = metrics
        let dark = effectiveAppearance.isDark
        let now = CACurrentMediaTime()

        while hitLayers.count < layout.slots.count {
            let hit = CALayer()
            hit.backgroundColor = NSColor(white: 1, alpha: 1 / 255).cgColor
            hit.zPosition = -1
            root.addSublayer(hit)
            hitLayers.append(hit)
        }
        for (i, hit) in hitLayers.enumerated() {
            guard i < layout.slots.count else {
                hit.isHidden = true
                continue
            }
            let low = i == 0 ? layout.start : (layout.slots[i - 1].center + layout.slots[i].center) / 2
            let high = i == layout.slots.count - 1 ? layout.end : (layout.slots[i].center + layout.slots[i + 1].center) / 2
            hit.frame = viewRect(u0: low, u1: high, v0: 0, v1: reach(of: i, in: layout))
            hit.isHidden = false
        }

        var seen = Set<String>()
        var separators = 0
        for (i, tile) in tiles.enumerated() where i < layout.slots.count {
            let slot = layout.slots[i]
            switch tile.kind {
            case .spacer, .smallSpacer:
                continue
            case .separator:
                if separators == separatorLayers.count {
                    separatorLayers.append(CALayer())
                    root.addSublayer(separatorLayers[separators])
                }
                let line = separatorLayers[separators]
                separators += 1
                line.isHidden = false
                line.frame = backingAlignedRect(viewRect(u0: slot.center - 0.5, u1: slot.center + 0.5, v0: iconBase, v1: iconBase + m.tile),
                                                options: .alignAllEdgesNearest)
                line.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.4) : NSColor(white: 0, alpha: 0.18)).cgColor
            default:
                seen.insert(tile.id)
                var layers = tileLayers[tile.id] ?? makeTileLayers(in: root)
                let size = m.tile * slot.scale
                let lift = bounceLift(tile.id, size: size, now: now)
                let rect = viewRect(u0: slot.center - size / 2, u1: slot.center + size / 2,
                                    v0: iconBase + lift, v1: iconBase + lift + size)
                let darken = (tile.id == pressedID && pressInside) || tile.id == dropID
                let image = darken ? darkBitmap(for: tile.id) : bitmap(for: tile.id)
                if image !== layers.image {
                    layers.icon.contents = image
                    layers.image = image
                }
                layers.icon.frame = rect
                layers.icon.opacity = dimHiddenApps && tile.hidden ? 0.5 : 1

                if let text = tile.badge, let badge = badgeImage(text) {
                    if layers.badgeText != text {
                        layers.badge.contents = badge
                        layers.badgeText = text
                    }
                    // A 16 pt circle at a 42 pt tile, in the icon's top-right corner, stretched for longer text.
                    let height = size * 16 / 42, inset = size * 0.5 / 42
                    let width = height * CGFloat(badge.width) / CGFloat(max(1, badge.height))
                    layers.badge.frame = NSRect(x: rect.maxX - inset - width, y: rect.maxY - inset - height, width: width, height: height)
                    layers.badge.isHidden = false
                } else {
                    layers.badge.isHidden = true
                    layers.badgeText = nil
                }

                if showIndicators && tile.isRunning {
                    let d = m.dotDiameter
                    let c = viewPoint(u: slot.center, v: BarMetrics.edgeMargin + slideOffset + m.dotOffset)
                    layers.dot.frame = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                    layers.dot.cornerRadius = d / 2
                    layers.dot.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.6)).cgColor
                    layers.dot.isHidden = false
                } else {
                    layers.dot.isHidden = true
                }
                tileLayers[tile.id] = layers
            }
        }
        for (id, layers) in tileLayers where !seen.contains(id) {
            [layers.icon, layers.badge, layers.dot].forEach { $0.removeFromSuperlayer() }
            tileLayers[id] = nil
        }
        for line in separatorLayers.dropFirst(separators) { line.isHidden = true }
    }

    private func makeTileLayers(in root: CALayer) -> TileLayers {
        let layers = TileLayers()
        for layer in [layers.icon, layers.badge] {
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
        }
        // Badges and dots sit above every icon, even a magnified neighbour's.
        layers.badge.zPosition = 1
        layers.dot.zPosition = 1
        [layers.icon, layers.badge, layers.dot].forEach(root.addSublayer)
        return layers
    }

    /// Forgets the bitmaps (for a new display, size or appearance) and lays out again.
    private func renderAgain() {
        bitmaps.removeAll()
        darkBitmaps.removeAll()
        badgeImages.removeAll()
        updateLayers()
    }

    /// The icon's bitmap, made the first time it's needed at the largest size it's drawn (again when
    /// the icon, the bar's size, the display or the appearance changes), in the window's colours.
    private func bitmap(for id: String) -> CGImage? {
        guard let icon = icons[id] else { return nil }
        if let cached = bitmaps[id], cached.icon === icon { return cached.image }
        darkBitmaps[id] = nil
        let side = Int((metrics.tile * maxScale * (window?.backingScaleFactor ?? 2)).rounded(.up))
        guard let image = render(width: side, height: side, draw: { rect in
            icon.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        }) else { return nil }
        bitmaps[id] = (icon, image)
        return image
    }

    /// The icon darkened as the Dock darkens one being pressed, or one a file would be dropped on.
    private func darkBitmap(for id: String) -> CGImage? {
        if let cached = darkBitmaps[id] { return cached }
        guard let base = bitmap(for: id) else { return nil }
        let image = render(width: base.width, height: base.height) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.draw(base, in: rect)
            context.setBlendMode(.sourceAtop)
            context.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            context.fill(rect)
        }
        darkBitmaps[id] = image
        return image
    }

    /// The red notification badge, made at the largest icon size: a capsule as tall as 16/42 of
    /// the icon, wide enough for the text.
    private func badgeImage(_ text: String) -> CGImage? {
        if let cached = badgeImages[text] { return cached }
        let scale = window?.backingScaleFactor ?? 2
        let height = metrics.tile * maxScale * 16 / 42 * scale
        let font = NSFont.systemFont(ofSize: height * 0.55)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = max(height, textSize.width + height * 0.35)
        let image = render(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) { rect in
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            (text as NSString).draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                                    withAttributes: attributes)
        }
        badgeImages[text] = image
        return image
    }

    /// Draws into a new bitmap of `width` × `height` pixels in the window's colour space and appearance.
    private func render(width: Int, height: Int, draw: (NSRect) -> Void) -> CGImage? {
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard width > 0, height > 0, let space,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            draw(NSRect(x: 0, y: 0, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { controller?.manager.pointerMoved() }
    override func mouseMoved(with event: NSEvent) { controller?.manager.pointerMoved() }
    override func mouseExited(with event: NSEvent) { controller?.manager.pointerMoved() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        guard let i = tileIndex(at: convert(event.locationInWindow, from: nil)), tiles[i].isActionable else { return }
        pressedID = tiles[i].id
        pressInside = true
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.manager.pointerMoved()
        guard let id = pressedID else { return }
        let inside = tileIndex(at: convert(event.locationInWindow, from: nil)).map { tiles[$0].id == id } ?? false
        if inside != pressInside {
            pressInside = inside
            updateLayers()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let id = pressedID else { return }
        pressedID = nil
        updateLayers()
        if let i = tileIndex(at: convert(event.locationInWindow, from: nil)), tiles[i].id == id {
            controller?.manager.open(tiles[i], from: iconRectOnScreen(i))
        }
    }

    /// Where tile `i`'s icon is drawn right now, in screen coordinates.
    private func iconRectOnScreen(_ i: Int) -> NSRect? {
        guard let window, layout.slots.indices.contains(i) else { return nil }
        let slot = layout.slots[i]
        let size = metrics.tile * slot.scale
        let rect = viewRect(u0: slot.center - size / 2, u1: slot.center + size / 2, v0: iconBase, v1: iconBase + size)
        return window.convertToScreen(convert(rect, to: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    private func showMenu(for event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = tileIndex(at: point)
        menuOpen = true
        controller.menuWillOpen()
        controller.startAnimating()
        if let i = index, tiles[i].isActionable {
            let menu = controller.manager.menu(for: tiles[i])
            menu.popUp(positioning: nil, at: menuOrigin(for: i, menuSize: menu.size), in: self)
        } else {
            NSMenu.popUpContextMenu(controller.manager.appMenu(), with: event, for: self)
        }
        menuOpen = false
        controller.menuDidClose()
        controller.startAnimating()
    }

    /// Where the Dock puts a tile's menu: just past the resting bar, beside the icon (above it for a
    /// bottom Dock), starting a little before the icon's centre for a side Dock.
    private func menuOrigin(for i: Int, menuSize: NSSize) -> NSPoint {
        let (starts, lengths, _, _) = restingSlots()
        let anchor = viewPoint(u: starts[i] + lengths[i] / 2, v: BarMetrics.edgeMargin + metrics.thickness + 13)
        switch orientation {
        case .bottom: return NSPoint(x: anchor.x - menuSize.width / 2, y: anchor.y + menuSize.height)
        case .left: return NSPoint(x: anchor.x, y: anchor.y + 25)
        case .right: return NSPoint(x: anchor.x - menuSize.width, y: anchor.y + 25)
        }
    }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropTarget(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil) }
        guard let controller, let id = dropID, let tile = tiles.first(where: { $0.id == id }) else { return false }
        return controller.manager.drop(fileURLs(sender), on: tile)
    }

    private func dragMoved(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Magnify under a dragged file as under the pointer.
        controller?.manager.pointerMoved()
        guard let controller, let i = tileIndex(at: convert(sender.draggingLocation, from: nil)) else {
            setDropTarget(nil)
            return []
        }
        let operation = controller.manager.dropOperation(for: tiles[i], urls: fileURLs(sender),
                                                         allowed: sender.draggingSourceOperationMask)
        setDropTarget(operation.isEmpty ? nil : tiles[i].id)
        return operation
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func setDropTarget(_ id: String?) {
        if dropID != id {
            dropID = id
            updateLayers()
        }
    }
}
