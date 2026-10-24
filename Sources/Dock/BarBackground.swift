import AppKit

/// The bar's rounded background: Liquid Glass on macOS 26 and later, vibrancy before that.
@MainActor
final class BarBackground {
    let view: NSView
    /// Glass draws its own soft edge; a window shadow would add a dark outline the Dock doesn't have.
    let wantsWindowShadow: Bool
    private let shade: GlassShade?
    private let border: BorderView?

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { applyCornerRadius() } }
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        #if compiler(>=6.2)
        if #available(macOS 26, *), !Settings.shared.legacyBackground {
            let container = NSView()
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.autoresizingMask = [.width, .height]
            let shade = GlassShade()
            shade.cornerRadius = cornerRadius
            shade.autoresizingMask = [.width, .height]
            container.addSubview(glass)
            container.addSubview(shade)
            view = container
            self.shade = shade
            border = nil
            wantsWindowShadow = false
            return
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let border = BorderView()
        border.autoresizingMask = [.width, .height]
        effect.addSubview(border)
        view = effect
        self.border = border
        shade = nil
        wantsWindowShadow = true
        applyCornerRadius()
    }

    func setFrame(_ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }

    private func applyCornerRadius() {
        #if compiler(>=6.2)
        if #available(macOS 26, *), let glass = view.subviews.first as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            shade?.cornerRadius = cornerRadius
            return
        }
        #endif
        (view as? NSVisualEffectView)?.maskImage = Self.mask(cornerRadius)
        border?.cornerRadius = cornerRadius
    }

    /// A stretchable rounded-rectangle mask, so resizing the bar keeps its corners.
    private static func mask(_ radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Brings AppKit's regular glass to the Dock's tone. Measured over the same backdrops in dark
/// mode, the Dock's glass is the regular glass minus about 18 levels per channel, which a
/// plus-darker layer of 93% white reproduces (colours included).
final class GlassShade: NSView {
    var cornerRadius: CGFloat = 12 {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        if effectiveAppearance.isDark {
            layer.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
            layer.compositingFilter = "plusD"
        } else {
            layer.backgroundColor = nil
            layer.compositingFilter = nil
        }
    }
}

/// The hairline around the pre-glass bar.
final class BorderView: NSView {
    var cornerRadius: CGFloat = 12 {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, cornerRadius - 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        (effectiveAppearance.isDark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
