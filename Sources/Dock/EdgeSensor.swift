import AppKit

/// A one-point strip along a display's Dock edge, shown while that display's bar is hidden. It tells
/// the bar when the pointer reaches the edge (which reveals the bar, and is how the Dock moves to
/// another display) without DeskKit having to watch every pointer move on every screen.
@MainActor
final class EdgeSensor {
    var onPointer: (() -> Void)?
    private let panel: NSPanel

    init() {
        let frame = NSRect(x: 0, y: 0, width: 10, height: 1)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = SensorView(frame: frame)
        view.autoresizingMask = [.width, .height]
        view.sensor = self
        panel.contentView = view
    }

    /// Shows the sensor along `edge` (a one-point strip in screen coordinates).
    func show(along edge: NSRect) {
        if panel.frame != edge { panel.setFrame(edge, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    fileprivate func touched() {
        onPointer?()
    }
}

private final class SensorView: NSView {
    weak var sensor: EdgeSensor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        // Dragging a file to the edge reveals the bar too, as it does the Dock.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The window server lets the pointer through fully transparent pixels; this is invisible but counts.
        NSColor(white: 1, alpha: 1 / 255).setFill()
        bounds.fill()
    }

    override func mouseEntered(with event: NSEvent) { sensor?.touched() }
    override func mouseMoved(with event: NSEvent) { sensor?.touched() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sensor?.touched()
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sensor?.touched()
        return []
    }
}
