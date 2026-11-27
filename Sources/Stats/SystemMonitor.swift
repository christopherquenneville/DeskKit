import AppKit
import notify

/// macOS's thermal pressure: how hard it's holding the Mac back to keep it cool. These are the
/// levels `powermetrics` shows. ProcessInfo's thermalState has only four, and calls both moderate
/// and heavy "fair", so DeskKit reads the level macOS posts instead.
enum ThermalPressure: Int, Sendable {
    case nominal, moderate, heavy, trapping, sleeping

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .moderate
        case .serious: self = .trapping
        case .critical: self = .sleeping
        @unknown default: self = .nominal
        }
    }

    var name: String {
        switch self {
        case .nominal: return "nominal"
        case .moderate: return "moderate"
        case .heavy: return "heavy"
        case .trapping: return "trapping"
        case .sleeping: return "sleeping"
        }
    }

    /// Whether macOS is slowing the Mac down to cool it: heavy pressure is where that starts.
    var throttling: String {
        switch self {
        case .nominal: return "None"
        case .moderate: return "Not yet, running warm"
        case .heavy: return "Yes, slowed to cool down"
        case .trapping: return "Yes, heavily"
        case .sleeping: return "Yes, about to sleep"
        }
    }

    var color: NSColor {
        switch self {
        case .nominal: return .systemGreen
        case .moderate: return .systemYellow
        case .heavy: return .systemOrange
        case .trapping, .sleeping: return .systemRed
        }
    }
}

/// Memory pressure as the kernel reports it (and Activity Monitor colours its graph).
enum MemoryPressure: Sendable {
    case normal, warning, critical

    /// The kernel's sysctl gives the dispatch levels: 1 normal, 2 warning, 4 critical.
    init(level: Int32) {
        self = level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }
}

/// The kernel's running totals of CPU time, in ticks, across all cores.
struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    /// The share of time the cores were busy since `earlier`. The totals are 32-bit and wrap
    /// around after a few weeks, so the differences wrap too.
    func usage(since earlier: CPUTicks) -> Double? {
        let busy = Double(user &- earlier.user) + Double(system &- earlier.system) + Double(nice &- earlier.nice)
        let total = busy + Double(idle &- earlier.idle)
        return total > 0 ? busy / total : nil
    }
}

struct SystemSnapshot: Sendable {
    /// From 0 to 1; nil until there's an earlier reading to compare with.
    var cpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryPressure = MemoryPressure.normal
    /// In degrees Celsius.
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    /// False until DeskKit has looked for temperature sensors.
    var temperaturesSearched = false
    var thermalPressure = ThermalPressure.nominal

    var memoryShare: Double {
        memoryTotal > 0 ? min(1, Double(memoryUsed) / Double(memoryTotal)) : 0
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous pages that can't be purged), wired
    /// memory and the compressor's pages. Cached files don't count.
    static func memoryUsed(anonymous: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) -> UInt64 {
        (anonymous - min(anonymous, purgeable) + wired + compressed) * pageSize
    }
}

/// Reads CPU and memory use, temperatures and thermal pressure for the menu. Nothing runs in the
/// background: each reading is made when the menu asks, once a second while it's open.
final class SystemMonitor: @unchecked Sendable {
    static let shared = SystemMonitor()

    /// Whether this Mac has temperature sensors DeskKit can read: nil until it has looked.
    @MainActor private(set) var hasTemperatures: Bool?

    // Everything below is only used on `queue`.
    private let queue = DispatchQueue(label: "tech.quenneville.DeskKit.stats", qos: .userInitiated)
    private let host = mach_host_self()
    private var lastTicks: CPUTicks?
    private var lastTicksAt: TimeInterval = 0
    private var thermalToken: Int32?
    private var smc: SMC?
    private var sensors: TemperatureSensors?
    private var searching = false

    func sample(_ done: @escaping @MainActor (SystemSnapshot) -> Void) {
        queue.async {
            let snapshot = self.read()
            Task { @MainActor in
                if snapshot.temperaturesSearched {
                    self.hasTemperatures = snapshot.cpuTemperature != nil || snapshot.gpuTemperature != nil
                }
                done(snapshot)
            }
        }
    }

    private func read() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        // CPU use is a rate: compare with the last reading, if it's recent enough to mean something.
        let now = ProcessInfo.processInfo.systemUptime
        if let ticks = cpuTicks(), lastTicks == nil || now - lastTicksAt >= 0.25 {
            if let last = lastTicks, now - lastTicksAt < 10 { snapshot.cpu = ticks.usage(since: last) }
            lastTicks = ticks
            lastTicksAt = now
        }
        readMemory(into: &snapshot)
        snapshot.thermalPressure = thermalPressure()
        if let sensors {
            snapshot.temperaturesSearched = true
            if let smc {
                snapshot.cpuTemperature = TemperatureSensors.average(sensors.cpu.compactMap(smc.value))
                snapshot.gpuTemperature = TemperatureSensors.average(sensors.gpu.compactMap(smc.value))
            }
        } else if !searching {
            // The first look goes through every SMC key (a tenth of a second or so): after this reading.
            searching = true
            queue.async { self.findSensors() }
        }
        return snapshot
    }

    private func findSensors() {
        smc = SMC()
        sensors = smc.map(TemperatureSensors.find) ?? TemperatureSensors()
        let found = sensors.map { "\($0.cpu.count) CPU and \($0.gpu.count) GPU" } ?? "no"
        appLog.info("Found \(found, privacy: .public) temperature sensors")
        if sensors?.isEmpty == true { smc = nil }
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    private func readMemory(into snapshot: inout SystemSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return }
        snapshot.memoryUsed = SystemSnapshot.memoryUsed(anonymous: UInt64(stats.internal_page_count), purgeable: UInt64(stats.purgeable_count),
                                                        wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count),
                                                        pageSize: UInt64(pageSize))
        snapshot.memoryTotal = ProcessInfo.processInfo.physicalMemory
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            snapshot.memoryPressure = MemoryPressure(level: level)
        }
    }

    private func thermalPressure() -> ThermalPressure {
        if thermalToken == nil {
            var token: Int32 = 0
            thermalToken = notify_register_check(kOSThermalNotificationPressureLevelName, &token) == NOTIFY_STATUS_OK ? token : -1
        }
        var state: UInt64 = 0
        if let token = thermalToken, token >= 0, notify_get_state(token, &state) == NOTIFY_STATUS_OK,
           let pressure = ThermalPressure(rawValue: Int(state)) {
            return pressure
        }
        return ThermalPressure(ProcessInfo.processInfo.thermalState)
    }
}
