import AppKit

/// The name shown beside a hovered icon, in its own small panel that ignores the mouse.
@MainActor
final class LabelPanel {
    private static let height: CGFloat = 26
    private static let font = NSFont.systemFont(ofSize: 14)

    private let panel: NSPanel
    private let text = LabelText()
    private var owner: CGDirectDisplayID?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 80, height: Self.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        // Like the Dock's label: a capsule of glass (vibrancy before macOS 26), so whatever is
        // behind it is blurred rather than showing through.
        let content = NSView(frame: frame)
        let radius = Self.height / 2
        var background: NSView?
        #if compiler(>=6.2)
        if #available(macOS 26, *), !Settings.shared.legacyBackground {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = radius
            background = glass
        }
        #endif
        if background == nil {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .toolTip
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            background = effect
        }
        if let background {
            background.autoresizingMask = [.width, .height]
            content.addSubview(background)
        }
        text.frame = frame
        text.autoresizingMask = [.width, .height]
        content.addSubview(text)
        panel.contentView = content
    }

    /// Shows `string` just past `anchor` (screen coordinates), on the side away from the Dock's edge.
    func show(_ string: String, at anchor: NSPoint, orientation: DockOrientation, owner: CGDirectDisplayID) {
        self.owner = owner
        text.string = string
        let width = ceil((string as NSString).size(withAttributes: [.font: Self.font]).width) + 27
        let size = NSSize(width: width, height: Self.height)
        let origin: NSPoint
        switch orientation {
        case .bottom: origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        case .left: origin = NSPoint(x: anchor.x, y: anchor.y - size.height / 2)
        case .right: origin = NSPoint(x: anchor.x - size.width, y: anchor.y - size.height / 2)
        }
        let frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide(owner: CGDirectDisplayID) {
        guard self.owner == owner else { return }
        self.owner = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    fileprivate static var textFont: NSFont { font }
}

/// The label's text, over a faint wash that lifts the glass to the Dock label's tone.
private final class LabelText: NSView {
    var string = "" {
        didSet { if string != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(white: 1, alpha: dark ? 0.06 : 0.2).setFill()
        capsule.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: LabelPanel.textFont,
            .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85),
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                  withAttributes: attributes)
    }
}
