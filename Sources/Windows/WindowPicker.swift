import AppKit

/// A small panel listing an app's windows, with previews, shown when its icon is clicked in the Dock
/// or a bar while it has more than one window. Choosing a window brings just that one forward; the
/// X on a preview closes that window and leaves the picker open for the rest.
@MainActor
final class WindowPicker: NSObject, NSWindowDelegate {
    private var panel: PickerPanel?
    private var app: NSRunningApplication?
    private var windows: [AppWindow] = []
    private var anchor = NSRect.zero
    private var edge = DockOrientation.bottom
    private var previews: [CGWindowID: CGImage] = [:]
    private var cells: [PickerCell] = []
    private var selection: Int? {
        didSet { for (i, cell) in cells.enumerated() { cell.isSelected = i == selection } }
    }
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    /// The app whose picker a click in one of DeskKit's bars just closed, and when: if that click
    /// was on the same app's icon, it closes the picker rather than opening it again.
    private var closedByClick: (pid: pid_t, time: CFTimeInterval)?
    private var pendingRaise: (app: NSRunningApplication, id: CGWindowID, tries: Int)?
    private var raiseTimer: Timer?
    /// A window asked to close, watched until it's gone or shows a sheet (asking to save, say).
    private var closing: (window: AXUIElement, since: CFTimeInterval)?
    private var closeTimer: Timer?

    private enum Layout {
        static let padding: CGFloat = 14
        static let header: CGFloat = 22
        static let headerGap: CGFloat = 10
        static let preview = CGSize(width: 200, height: 124)
        static let title: CGFloat = 34
        static let spacing: CGFloat = 8
        static let cornerRadius: CGFloat = 18
        static let gap: CGFloat = 12
    }

    var isShowing: Bool { panel != nil }

    /// Shows the picker for an app with several windows beside its icon (`anchor`, in screen
    /// coordinates), on the side away from `edge`. Clicking the same icon again closes it.
    /// Returns false, showing nothing, when the app has fewer than two windows.
    @discardableResult
    func show(for app: NSRunningApplication, windows known: [AppWindow]? = nil, anchor: NSRect, edge: DockOrientation) -> Bool {
        let pid = app.processIdentifier
        if let closed = closedByClick, closed.pid == pid, CACurrentMediaTime() - closed.time < 0.5 {
            closedByClick = nil
            return true
        }
        if isShowing && self.app?.processIdentifier == pid {
            dismiss()
            return true
        }
        dismiss()
        let windows = known ?? WindowList.windows(of: pid)
        guard windows.count >= 2 else { return false }
        self.app = app
        self.windows = windows
        self.anchor = anchor
        self.edge = edge
        layOut()
        guard let panel else { return false }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)

        // Any click outside DeskKit closes it; clicks in DeskKit's other windows close it too.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window !== panel else { return }
                self.closedByClick = (pid, CACurrentMediaTime())
                self.dismiss()
            }
            return event
        }

        // Previews at full size, so they stay sharp if closing windows makes room for bigger ones.
        let scale = panel.screen?.backingScaleFactor ?? 2
        WindowPreviews.capture(windows.compactMap(\.id), fitting: Layout.preview, scale: scale) { [weak self] id, image in
            guard let self, self.panel === panel else { return }
            self.previews[id] = image
            if let i = self.windows.firstIndex(where: { $0.id == id }) { self.cells[i].preview = image }
        }
        return true
    }

    func dismiss() {
        for monitor in [clickMonitor, localClickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        localClickMonitor = nil
        stopWatchingClose()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        cells = []
        selection = nil
        app = nil
        windows = []
        previews = [:]
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    // MARK: Choosing

    fileprivate func choose(_ index: Int) {
        guard let app, windows.indices.contains(index) else { return }
        let window = windows[index]
        dismiss()
        if !WindowList.raise(window, of: app), let id = window.id {
            // On another Space: give macOS a moment to switch there, then raise that window.
            pendingRaise = (app, id, 0)
            raiseTimer?.invalidate()
            let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(retryRaise(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            raiseTimer = timer
        }
    }

    @objc private func retryRaise(_ timer: Timer) {
        guard let pending = pendingRaise else {
            timer.invalidate()
            return
        }
        if WindowList.raiseOnceReachable(pending.id, of: pending.app) || pending.tries >= 8 {
            pendingRaise = nil
            timer.invalidate()
            raiseTimer = nil
        } else {
            pendingRaise?.tries += 1
        }
    }

    fileprivate func moveSelection(by step: Int) {
        guard !cells.isEmpty else { return }
        let current = selection ?? (step > 0 ? -1 : cells.count)
        selection = min(max(current + step, 0), cells.count - 1)
    }

    fileprivate func chooseSelection() {
        if let selection { choose(selection) }
    }

    fileprivate func closeSelection() {
        if let selection { closeWindow(selection) }
    }

    fileprivate var columns: Int {
        guard let first = cells.first else { return 1 }
        return cells.filter { abs($0.frame.minY - first.frame.minY) < 1 }.count
    }

    // MARK: Closing windows

    /// Presses the window's own close button, as clicking it would.
    fileprivate func closeWindow(_ index: Int) {
        guard closing == nil, windows.indices.contains(index), let window = windows[index].element,
              let button = AX.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString) == .success else {
            NSSound.beep()
            return
        }
        cells[index].isClosing = true
        closing = (window, CACurrentMediaTime())
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(checkClosing(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    @objc private func checkClosing(_ timer: Timer) {
        guard let (window, since) = closing, let app else {
            stopWatchingClose()
            return
        }
        let index = windows.firstIndex { $0.element.map { CFEqual($0, window) } ?? false }
        guard AX.windows(of: app.processIdentifier).contains(where: { CFEqual($0, window) }) else {
            // Closed: drop it, and make the picker fit the rest.
            stopWatchingClose()
            if let index { windows.remove(at: index) }
            if windows.isEmpty { dismiss() } else { layOut() }
            return
        }
        let children = AX.attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if children.contains(where: { AX.string($0, kAXRoleAttribute) == kAXSheetRole }) {
            // The app is asking something first (whether to save, usually): show that window to answer it.
            stopWatchingClose()
            if let index { choose(index) }
        } else if CACurrentMediaTime() - since > 2 {
            stopWatchingClose()
            if let index { cells[index].isClosing = false }
        }
    }

    private func stopWatchingClose() {
        closeTimer?.invalidate()
        closeTimer = nil
        closing = nil
    }

    // MARK: Building

    /// Sizes and places the panel for the current windows, and fills it.
    private func layOut() {
        guard let app, !windows.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.screens.first
        let room = (screen?.usableFrame ?? .zero).insetBy(dx: 8, dy: 8)
        let count = windows.count
        let columns = min(count, max(4, Int(Double(count).squareRoot().rounded(.up))))
        let rows = (count + columns - 1) / columns
        // Shrink the previews if the grid wouldn't fit on the screen.
        let natural = gridSize(columns: columns, rows: rows, scale: 1)
        let scale = min(1, (room.width - 2 * Layout.padding) / (natural.width - 2 * Layout.padding),
                        (room.height - 2 * Layout.padding - Layout.header - Layout.headerGap)
                            / (natural.height - 2 * Layout.padding - Layout.header - Layout.headerGap))
        let size = gridSize(columns: columns, rows: rows, scale: scale)
        let frame = placement(size, anchor: anchor, edge: edge, room: room)

        let panel = self.panel ?? makePanel(frame)
        panel.setFrame(frame, display: false)
        let content = PickerContentView(frame: NSRect(origin: .zero, size: size))
        content.picker = self
        content.addSubview(makeBackground(size))
        addHeader(to: content, app: app)
        cells = makeCells(in: content, columns: columns, scale: scale, app: app)
        panel.contentView = content
        panel.initialFirstResponder = content
        if panel.isVisible { panel.makeFirstResponder(content) }
        self.panel = panel
        if let selection { self.selection = min(selection, cells.count - 1) }
    }

    private func makePanel(_ frame: NSRect) -> PickerPanel {
        let panel = PickerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        return panel
    }

    private func gridSize(columns: Int, rows: Int, scale: CGFloat) -> NSSize {
        let cell = NSSize(width: Layout.preview.width * scale, height: Layout.preview.height * scale + Layout.title)
        return NSSize(width: 2 * Layout.padding + CGFloat(columns) * cell.width + CGFloat(columns - 1) * Layout.spacing,
                      height: 2 * Layout.padding + Layout.header + Layout.headerGap
                          + CGFloat(rows) * cell.height + CGFloat(rows - 1) * Layout.spacing)
    }

    /// Beside the icon on the side away from the Dock's edge, kept on the screen.
    private func placement(_ size: NSSize, anchor: NSRect, edge: DockOrientation, room: NSRect) -> NSRect {
        var origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + Layout.gap)
        case .left: origin = NSPoint(x: anchor.maxX + Layout.gap, y: anchor.midY - size.height / 2)
        case .right: origin = NSPoint(x: anchor.minX - Layout.gap - size.width, y: anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, room.minX), room.maxX - size.width)
        origin.y = min(max(origin.y, room.minY), room.maxY - size.height)
        return NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    private func makeBackground(_ size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        #if compiler(>=6.2)
        if #available(macOS 26, *), !Settings.shared.legacyBackground {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = Layout.cornerRadius
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        #endif
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Layout.cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        return effect
    }

    private func addHeader(to content: NSView, app: NSRunningApplication) {
        let top = content.bounds.height - Layout.padding
        let icon = NSImageView(frame: NSRect(x: Layout.padding, y: top - 20, width: 20, height: 20))
        icon.image = app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let name = NSTextField(labelWithString: app.localizedName ?? "")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: Layout.padding + 26, y: top - 19, width: content.bounds.width - 2 * Layout.padding - 26, height: 17)
        content.addSubview(name)
    }

    private func makeCells(in content: NSView, columns: Int, scale: CGFloat, app: NSRunningApplication) -> [PickerCell] {
        let cellSize = NSSize(width: Layout.preview.width * scale, height: Layout.preview.height * scale + Layout.title)
        let top = content.bounds.height - Layout.padding - Layout.header - Layout.headerGap
        let lastRowCount = windows.count % columns == 0 ? columns : windows.count % columns
        let lastRow = (windows.count - 1) / columns
        var made: [PickerCell] = []
        for (i, window) in windows.enumerated() {
            let row = i / columns, column = i % columns
            // Centre a short last row.
            let inset = row == lastRow ? CGFloat(columns - lastRowCount) * (cellSize.width + Layout.spacing) / 2 : 0
            let origin = NSPoint(x: Layout.padding + inset + CGFloat(column) * (cellSize.width + Layout.spacing),
                                 y: top - CGFloat(row + 1) * cellSize.height - CGFloat(row) * Layout.spacing)
            let cell = PickerCell(frame: NSRect(origin: origin, size: cellSize), previewHeight: Layout.preview.height * scale)
            cell.title = window.title.isEmpty ? (app.localizedName ?? "Window") : window.title
            cell.subtitle = window.isMinimized ? "Minimized" : (window.isOnAnotherSpace ? "On another Space" : nil)
            cell.placeholder = app.icon
            cell.preview = window.id.flatMap { previews[$0] }
            // Windows on other Spaces can't be reached to close them.
            cell.canClose = window.element != nil
            cell.onClick = { [weak self] in self?.choose(i) }
            cell.onClose = { [weak self] in self?.closeWindow(i) }
            cell.onHover = { [weak self] inside in if inside { self?.selection = i } }
            content.addSubview(cell)
            made.append(cell)
        }
        return made
    }
}

/// A panel that can take the keyboard (for Esc, arrows, Return and ⌘W) without activating DeskKit.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerContentView: NSView {
    weak var picker: WindowPicker?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let picker, modifiers == .command, event.charactersIgnoringModifiers == "w" {
            picker.closeSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let picker else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: picker.dismiss()                              // Esc
        case 36, 76, 49: picker.chooseSelection()              // Return, Enter, Space
        case 123: picker.moveSelection(by: -1)                 // ←
        case 124: picker.moveSelection(by: 1)                  // →
        case 126: picker.moveSelection(by: -picker.columns)    // ↑
        case 125: picker.moveSelection(by: picker.columns)     // ↓
        default: super.keyDown(with: event)
        }
    }
}

/// One window in the picker: its preview (or the app's icon until the preview arrives), title, and
/// an X that closes the window, shown while the pointer is over it or it's selected.
final class PickerCell: NSView {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true; updateCloseButton() } }
    }
    var canClose = false {
        didSet { updateCloseButton() }
    }
    /// The window was asked to close: dim it until it goes.
    var isClosing = false {
        didSet { alphaValue = isClosing ? 0.4 : 1 }
    }
    var title = "" {
        didSet { titleLabel.stringValue = title }
    }
    var subtitle: String? {
        didSet { layoutText() }
    }
    var placeholder: NSImage? {
        didSet { if preview == nil { showPlaceholder() } }
    }
    var preview: CGImage? {
        didSet { if let preview { show(preview) } }
    }

    private let previewHeight: CGFloat
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let closeButton = CloseButton()
    private var isHovered = false

    init(frame: NSRect, previewHeight: CGFloat) {
        self.previewHeight = previewHeight
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        for label in [titleLabel, subtitleLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        layoutText()

        let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor(white: 0.1, alpha: 0.8)]))
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Window")?
            .withSymbolConfiguration(symbol)
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Close Window (⌘W)"
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.isHidden = true
        addSubview(closeButton)

        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCloseButton()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateCloseButton()
        onHover?(false)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let dark = effectiveAppearance.isDark
        (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    private var previewBox: NSRect {
        NSRect(x: 6, y: bounds.height - previewHeight + 2, width: bounds.width - 12, height: previewHeight - 8)
    }

    private func layoutText() {
        let textTop = bounds.height - previewHeight
        if subtitle == nil {
            titleLabel.frame = NSRect(x: 6, y: textTop - 22, width: bounds.width - 12, height: 16)
            subtitleLabel.isHidden = true
        } else {
            titleLabel.frame = NSRect(x: 6, y: textTop - 18, width: bounds.width - 12, height: 16)
            subtitleLabel.frame = NSRect(x: 6, y: textTop - 32, width: bounds.width - 12, height: 13)
            subtitleLabel.stringValue = subtitle ?? ""
            subtitleLabel.isHidden = false
        }
    }

    private func showPlaceholder() {
        let box = previewBox
        let side = min(box.width, box.height) * 0.55
        imageView.frame = NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        imageView.layer?.borderWidth = 0
        imageView.image = placeholder
        placeCloseButton(at: NSPoint(x: box.maxX, y: box.maxY))
    }

    private func show(_ preview: CGImage) {
        let box = previewBox
        let fitted = WindowPreviews.fit(CGSize(width: preview.width, height: preview.height), into: box.size)
        imageView.frame = NSRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor(white: 0.5, alpha: 0.25).cgColor
        imageView.image = NSImage(cgImage: preview, size: fitted)
        placeCloseButton(at: NSPoint(x: imageView.frame.maxX, y: imageView.frame.maxY))
    }

    /// Over the preview's top-right corner (kept inside the cell, which may clip).
    private func placeCloseButton(at corner: NSPoint) {
        let side: CGFloat = 20
        closeButton.frame = NSRect(x: min(corner.x - side + 5, bounds.width - side), y: min(corner.y - side + 5, bounds.height - side),
                                   width: side, height: side)
    }

    private func updateCloseButton() {
        closeButton.isHidden = !(canClose && (isHovered || isSelected))
    }
}

/// The X on a window's preview; it works on the first click even though DeskKit isn't active.
private final class CloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
