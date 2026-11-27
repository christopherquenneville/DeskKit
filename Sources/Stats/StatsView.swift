import AppKit

/// The top of DeskKit's menu: CPU and memory use, memory pressure, temperatures and throttling,
/// read again every second while the menu is open. Nothing is read while it's closed.
@MainActor
final class StatsView: NSView {
    private let cpuBar = MeterView()
    private let memoryBar = MeterView()
    private let cpuValue = StatsView.valueField()
    private let memoryValue = StatsView.valueField()
    private let pressureValue = StatsView.valueField()
    private let pressureDot = StatsView.dot()
    private let temperatureValue = StatsView.valueField()
    private let throttlingValue = StatsView.valueField()
    private let throttlingDot = StatsView.dot()
    private var timer: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        var rows: [[NSView]] = [
            [Self.nameField("CPU"), cpuBar, cpuValue],
            [Self.nameField("Memory"), memoryBar, memoryValue],
            [Self.nameField("Pressure"), Self.status(pressureDot, pressureValue), NSGridCell.emptyContentView],
        ]
        // Once DeskKit knows this Mac has no sensors it can read, the row goes.
        if SystemMonitor.shared.hasTemperatures != false {
            rows.append([Self.nameField("Temperature"), temperatureValue, NSGridCell.emptyContentView])
        }
        rows.append([Self.nameField("Throttling"), Self.status(throttlingDot, throttlingValue), NSGridCell.emptyContentView])
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 10
        grid.rowSpacing = 5
        grid.yPlacement = .center
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 2).width = ceil(("100%" as NSString).size(withAttributes: [.font: Self.valueFont]).width) + 2
        for index in 2..<grid.numberOfRows {
            grid.row(at: index).mergeCells(in: NSRange(location: 1, length: 2))
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        // Wide enough for the longest values, so nothing is cut off when they change.
        pressureValue.stringValue = MemoryPressure.allLevels.map(\.summary).max { $0.count < $1.count } ?? ""
        temperatureValue.stringValue = StatsFormat.temperatures(cpu: 100, gpu: 100, searched: true)
        throttlingValue.stringValue = ThermalPressure.allLevels.map(\.throttling).max { $0.count < $1.count } ?? ""
        frame.size = fittingSize
        autoresizingMask = [.width]

        cpuValue.stringValue = "–"
        memoryValue.stringValue = "–"
        pressureValue.stringValue = "–"
        temperatureValue.stringValue = StatsFormat.temperatures(cpu: nil, gpu: nil, searched: false)
        throttlingValue.stringValue = "–"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Refreshing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        if let menu = enclosingMenuItem?.menu {
            NotificationCenter.default.addObserver(self, selector: #selector(menuClosed(_:)), name: NSMenu.didEndTrackingNotification, object: menu)
        }
        refresh()
        // CPU use needs a second reading to compare with: the first comes soon after the menu opens.
        let timer = Timer(fireAt: Date(timeIntervalSinceNow: 0.4), interval: 1, target: self, selector: #selector(tick(_:)),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuClosed(_ note: Notification) {
        stop()
    }

    @objc private func tick(_ timer: Timer) {
        guard window != nil else { return stop() }
        refresh()
    }

    private func refresh() {
        SystemMonitor.shared.sample { [weak self] snapshot in
            self?.show(snapshot)
        }
    }

    private func show(_ snapshot: SystemSnapshot) {
        if let cpu = snapshot.cpu {
            cpuBar.share = cpu
            cpuValue.stringValue = StatsFormat.percent(cpu)
        }
        if snapshot.memoryTotal > 0 {
            memoryBar.share = snapshot.memoryShare
            switch snapshot.memoryPressure {
            case .normal: memoryBar.color = .controlAccentColor
            case .warning: memoryBar.color = .systemYellow
            case .critical: memoryBar.color = .systemRed
            }
            memoryValue.stringValue = StatsFormat.percent(snapshot.memoryShare)
            let detail = "\(StatsFormat.gigabytes(snapshot.memoryUsed)) of \(StatsFormat.gigabytes(snapshot.memoryTotal)) in use"
            memoryBar.toolTip = detail
            memoryValue.toolTip = detail
            pressureValue.stringValue = snapshot.memoryPressure.summary
            pressureValue.toolTip = snapshot.memoryPressure.detail
            pressureDot.contentTintColor = snapshot.memoryPressure.color
        }
        temperatureValue.stringValue = StatsFormat.temperatures(cpu: snapshot.cpuTemperature, gpu: snapshot.gpuTemperature,
                                                                searched: snapshot.temperaturesSearched)
        throttlingValue.stringValue = snapshot.thermalPressure.throttling
        throttlingValue.toolTip = "macOS reports \(snapshot.thermalPressure.name) thermal pressure"
        throttlingDot.contentTintColor = snapshot.thermalPressure.color
    }

    // MARK: Text

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)

    /// A small coloured dot for a status, like the one Activity Monitor's graphs suggest.
    private static func dot() -> NSImageView {
        let view = NSImageView()
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        view.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        view.contentTintColor = .tertiaryLabelColor
        view.setAccessibilityElement(false)
        return view
    }

    private static func status(_ dot: NSImageView, _ text: NSTextField) -> NSStackView {
        let stack = NSStackView(views: [dot, text])
        stack.spacing = 5
        return stack
    }

    private static func nameField(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = .secondaryLabelColor
        return field
    }

    private static func valueField() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = valueFont
        field.textColor = .labelColor
        field.lineBreakMode = .byClipping
        return field
    }
}

extension ThermalPressure {
    static let allLevels: [ThermalPressure] = [.nominal, .moderate, .heavy, .trapping, .sleeping]
}

/// Text for the stats, in the user's units (degrees Fahrenheit where the region uses them).
@MainActor
enum StatsFormat {
    static func percent(_ share: Double) -> String {
        "\(Int((max(0, min(1, share)) * 100).rounded()))%"
    }

    /// In gigabytes of 2³⁰ bytes, as Activity Monitor counts memory.
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value.formatted(.number.precision(.fractionLength(0...1))) + " GB"
    }

    private static let temperatureFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    static func temperature(_ celsius: Double) -> String {
        temperatureFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    static func temperatures(cpu: Double?, gpu: Double?, searched: Bool) -> String {
        let parts = [cpu.map { "CPU \(temperature($0))" }, gpu.map { "GPU \(temperature($0))" }].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return searched ? "Not available" : "…"
    }
}

/// A thin bar filled to a share from 0 to 1.
final class MeterView: NSView {
    var share: Double = 0 {
        didSet { if share != oldValue { needsDisplay = true } }
    }

    var color: NSColor = .controlAccentColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard share > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, (bounds.width * CGFloat(min(share, 1))).rounded())
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
