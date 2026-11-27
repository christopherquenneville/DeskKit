import Foundation
import IOKit

/// Reads the System Management Controller, the chip that runs a Mac's fans and watches its
/// temperatures, through IOKit. Apple doesn't document the SMC: the protocol and key names here are
/// the ones tools such as Stats and macmon use. Not thread-safe; use it from one queue.
final class SMC {
    struct KeyInfo: Equatable {
        let size: Int
        let type: UInt32
    }

    private var connection: io_connect_t = 0
    private var infos: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// How many keys the SMC has.
    var keyCount: Int {
        value(Self.code("#KEY")).map { Int($0) } ?? 0
    }

    /// The key at `index` of the SMC's list, for going through them all.
    func key(at index: Int) -> UInt32? {
        guard let output = call(Self.readIndex, { Self.store(UInt32(index), at: Self.indexOffset, in: &$0) }) else { return nil }
        return Self.load(at: Self.keyOffset, in: output)
    }

    func info(_ key: UInt32) -> KeyInfo? {
        if let info = infos[key] { return info }
        guard let output = call(Self.readKeyInfo, { Self.store(key, at: Self.keyOffset, in: &$0) }) else { return nil }
        let info = KeyInfo(size: Int(Self.load(at: Self.sizeOffset, in: output)), type: Self.load(at: Self.typeOffset, in: output))
        infos[key] = info
        return info
    }

    /// A key's value as a number, for the types that temperatures and counts use.
    func value(_ key: UInt32) -> Double? {
        guard let info = info(key), (1...32).contains(info.size) else { return nil }
        guard let output = call(Self.readBytes, {
            Self.store(key, at: Self.keyOffset, in: &$0)
            Self.store(UInt32(info.size), at: Self.sizeOffset, in: &$0)
        }) else { return nil }
        return Self.decode(Array(output[Self.bytesOffset ..< Self.bytesOffset + info.size]), type: info.type)
    }

    // MARK: Codes and values

    /// A four-character name ("Tp01", "flt ") as the number the SMC uses for it.
    static func code(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func text(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    /// Apple silicon's sensors are little-endian floats; Intel's temperatures are "sp78" (signed,
    /// 8 fractional bits) and the SMC's integers are big-endian.
    static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        switch text(type) {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    // MARK: Calls

    // The AppleSMC user client takes and returns one 80-byte struct (SMCKeyData_t); these are the
    // offsets of the fields DeskKit uses.
    private static let structSize = 80
    private static let keyOffset = 0
    private static let sizeOffset = 28
    private static let typeOffset = 32
    private static let resultOffset = 40
    private static let commandOffset = 42
    private static let indexOffset = 44
    private static let bytesOffset = 48
    private static let readBytes: UInt8 = 5
    private static let readIndex: UInt8 = 8
    private static let readKeyInfo: UInt8 = 9
    private static let method: UInt32 = 2

    private func call(_ command: UInt8, _ fill: (inout [UInt8]) -> Void) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        fill(&input)
        input[Self.commandOffset] = command
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, Self.method, input.baseAddress, Self.structSize, output.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess, output[Self.resultOffset] == 0 else { return nil }
        return output
    }

    /// The struct's own fields are in the CPU's byte order (little-endian on every Mac).
    private static func store(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    private static func load(at offset: Int, in bytes: [UInt8]) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

/// The SMC sensors DeskKit averages for the CPU's and the GPU's temperature.
struct TemperatureSensors {
    var cpu: [UInt32] = []
    var gpu: [UInt32] = []

    var isEmpty: Bool { cpu.isEmpty && gpu.isEmpty }

    /// At most this many of each, spread across the list: an SMC read takes about a tenth of a
    /// millisecond, and an M5 Max has 84 GPU sensors within a degree or two of each other.
    static let limit = 24

    /// On Apple silicon the SMC has a float sensor for each part of the chip, named "Tp…" for the
    /// CPU and "Tg…" for the GPU. Intel Macs have fixed names for their die sensors.
    static func find(in smc: SMC) -> TemperatureSensors {
        var sensors = TemperatureSensors()
        let float = SMC.code("flt ")
        let cpuPrefix = SMC.code("Tp"), gpuPrefix = SMC.code("Tg")
        for index in 0 ..< smc.keyCount {
            guard let key = smc.key(at: index), key >> 16 == cpuPrefix || key >> 16 == gpuPrefix,
                  smc.info(key) == SMC.KeyInfo(size: 4, type: float), isPlausible(smc.value(key)) else { continue }
            if key >> 16 == cpuPrefix { sensors.cpu.append(key) } else { sensors.gpu.append(key) }
        }
        if sensors.isEmpty {
            func firstReadable(_ names: [String]) -> [UInt32] {
                names.map(SMC.code).first { isPlausible(smc.value($0)) }.map { [$0] } ?? []
            }
            sensors.cpu = firstReadable(["TC0D", "TC0E", "TC0F", "TCXC", "TC0P"])
            sensors.gpu = firstReadable(["TG0D", "TGDD", "TG0P", "TCGC"])
        }
        sensors.cpu = spread(sensors.cpu, limit: limit)
        sensors.gpu = spread(sensors.gpu, limit: limit)
        return sensors
    }

    /// Unread, missing or disconnected sensors read 0, or wildly out of range.
    static func isPlausible(_ celsius: Double?) -> Bool {
        guard let celsius else { return false }
        return celsius > 1 && celsius < 150
    }

    static func average(_ readings: [Double]) -> Double? {
        let good = readings.filter { isPlausible($0) }
        return good.isEmpty ? nil : good.reduce(0, +) / Double(good.count)
    }

    /// Up to `limit` items, evenly spaced through the list.
    static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        return (0..<limit).map { items[$0 * items.count / limit] }
    }
}
