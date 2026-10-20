import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(IOKit)
import IOKit
#endif

/// Where the Mac's unified memory is going, in bytes. Mirrors Activity Monitor's categories.
public struct MemoryBreakdown: Equatable, Sendable {
    public var total: UInt64 = 0
    /// Kernel and GPU-wired memory (cannot be paged out).
    public var wired: UInt64 = 0
    /// App memory: anonymous pages minus purgeable ones.
    public var apps: UInt64 = 0
    public var compressed: UInt64 = 0
    /// File cache and purgeable pages that macOS gives back on demand.
    public var cached: UInt64 = 0
    public var free: UInt64 = 0

    public init() {}

    public var used: UInt64 { wired + apps + compressed }

    /// Splits the breakdown for display, carving the model server's footprint out of wired and app
    /// memory (MLX buffers are GPU-wired, the rest is ordinary app memory).
    public func segments(modelBytes: UInt64) -> (model: UInt64, wired: UInt64, apps: UInt64, compressed: UInt64, cached: UInt64, free: UInt64) {
        let model = min(modelBytes, wired + apps)
        let fromWired = min(model, wired)
        let fromApps = model - fromWired
        return (model, wired - fromWired, apps - fromApps, compressed, cached, free)
    }
}

/// One reading of the whole machine.
public struct SystemSnapshot: Equatable, Sendable {
    public var time = Date()
    /// 0...1 across all cores.
    public var cpu: Double = 0
    /// 0...1 per logical core, in system order (efficiency cores first on Apple silicon).
    public var cpuCores: [Double] = []
    public var memory = MemoryBreakdown()
    public var swapBytes: UInt64 = 0
    /// 0...1, or nil when the GPU does not report it.
    public var gpu: Double?
    /// Memory the GPU currently has allocated (the "VRAM" in use on unified memory), or nil.
    public var gpuMemoryBytes: UInt64?
    public var thermal: ProcessInfo.ThermalState = .nominal

    public init() {}
}

public enum CPUMath {
    /// Busy fraction between two tick readings (user, system, idle, nice).
    public static func busy(from a: [UInt32], to b: [UInt32]) -> Double {
        guard a.count == 4, b.count == 4 else { return 0 }
        let d = (0..<4).map { Double(b[$0] &- a[$0]) }
        let total = d.reduce(0, +)
        guard total > 0 else { return 0 }
        return min(max((d[0] + d[1] + d[3]) / total, 0), 1)
    }
}

#if canImport(Darwin)
/// Reads CPU, memory and GPU load. Call `sample()` on a timer; CPU needs two readings, so the first
/// call reports zero. Not thread safe: use one instance from one place.
public final class SystemSampler: @unchecked Sendable {
    private var previous: [[UInt32]] = []
    private let totalMemory: UInt64

    public init() {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        totalMemory = size
    }

    public func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        let cores = readCores()
        if previous.count == cores.count {
            s.cpuCores = zip(previous, cores).map { CPUMath.busy(from: $0, to: $1) }
        } else {
            s.cpuCores = Array(repeating: 0, count: cores.count)
        }
        previous = cores
        s.cpu = s.cpuCores.isEmpty ? 0 : s.cpuCores.reduce(0, +) / Double(s.cpuCores.count)
        s.memory = readMemory()
        s.swapBytes = HardwareProbe.swapUsedBytes()
        let g = Self.readGPU()
        s.gpu = g.utilization
        s.gpuMemoryBytes = g.memoryBytes
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }

    private func readCores() -> [[UInt32]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        return (0..<Int(count)).map { i in
            let base = i * Int(CPU_STATE_MAX)
            return [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map { UInt32(bitPattern: info[base + Int($0)]) }
        }
    }

    private func readMemory() -> MemoryBreakdown {
        var m = MemoryBreakdown()
        m.total = totalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return m }
        let page = UInt64(vm_kernel_page_size)
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        m.apps = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        m.free = UInt64(stats.free_count) * page
        return m
    }

    /// GPU load and allocated memory from the IOAccelerator registry entry.
    static func readGPU() -> (utilization: Double?, memoryBytes: UInt64?) {
        #if canImport(IOKit)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }
        var util: Double?
        var mem: UInt64?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            let parsed = parseGPU(perf)
            util = parsed.utilization ?? util
            mem = parsed.memoryBytes ?? mem
        }
        return (util, mem)
        #else
        return (nil, nil)
        #endif
    }

    /// Pulls the numbers out of an IOAccelerator PerformanceStatistics dictionary.
    static func parseGPU(_ perf: [String: Any]) -> (utilization: Double?, memoryBytes: UInt64?) {
        func number(_ keys: [String]) -> Double? {
            for k in keys { if let n = perf[k] as? NSNumber { return n.doubleValue } }
            return nil
        }
        let util = number(["Device Utilization %", "GPU Activity(%)"]).map { min(max($0 / 100, 0), 1) }
        let mem = number(["In use system memory", "vramUsedBytes"]).map { UInt64(max($0, 0)) }
        return (util, mem)
    }
}
#endif
