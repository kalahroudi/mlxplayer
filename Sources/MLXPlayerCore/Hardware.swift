import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HardwareProfile: Codable, Equatable, Sendable {
    public var chip: String
    public var memoryBytes: UInt64
    public var gpuCores: Int
    public var cpuCores: Int
    public var performanceCores: Int
    /// Peak unified-memory bandwidth in GB/s.
    public var bandwidthGBs: Double
    /// True when the chip wasn't in the table and bandwidth is a guess.
    public var bandwidthIsEstimate: Bool
    /// Memory the GPU may wire (iogpu.wired_limit_mb, or the macOS default).
    public var gpuLimitBytes: UInt64
    /// Memory not in use by apps right now (free + inactive + purgeable).
    public var availableBytes: UInt64

    public init(chip: String, memoryBytes: UInt64, gpuCores: Int, cpuCores: Int, performanceCores: Int,
                bandwidthGBs: Double, bandwidthIsEstimate: Bool = false,
                gpuLimitBytes: UInt64? = nil, availableBytes: UInt64? = nil) {
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.gpuCores = gpuCores
        self.cpuCores = cpuCores
        self.performanceCores = performanceCores
        self.bandwidthGBs = bandwidthGBs
        self.bandwidthIsEstimate = bandwidthIsEstimate
        self.gpuLimitBytes = gpuLimitBytes ?? HardwareProfile.defaultGPULimit(memoryBytes: memoryBytes)
        self.availableBytes = availableBytes ?? memoryBytes
    }

    /// macOS wires about two thirds of RAM for the GPU on small Macs and three quarters on larger ones.
    public static func defaultGPULimit(memoryBytes: UInt64) -> UInt64 {
        let gb = Double(memoryBytes) / 1_073_741_824
        let fraction = gb <= 36 ? 2.0 / 3.0 : 0.75
        return UInt64(Double(memoryBytes) * fraction)
    }
}

/// Peak memory bandwidth by chip. Values are Apple's published figures.
public enum ChipTable {
    public static func bandwidth(chip: String, gpuCores: Int) -> (gbs: Double, estimate: Bool) {
        let name = chip.replacingOccurrences(of: "Apple ", with: "").trimmingCharacters(in: .whitespaces)
        switch name {
        case "M1": return (68.25, false)
        case "M1 Pro": return (200, false)
        case "M1 Max": return (400, false)
        case "M1 Ultra": return (800, false)
        case "M2": return (100, false)
        case "M2 Pro": return (200, false)
        case "M2 Max": return (gpuCores <= 30 ? 300 : 400, false)
        case "M2 Ultra": return (800, false)
        case "M3": return (100, false)
        case "M3 Pro": return (150, false)
        case "M3 Max": return (gpuCores <= 30 ? 300 : 400, false)
        case "M3 Ultra": return (819, false)
        case "M4": return (120, false)
        case "M4 Pro": return (273, false)
        case "M4 Max": return (gpuCores <= 32 ? 410 : 546, false)
        default: return (100, true)
        }
    }
}

public enum HardwareProbe {
    /// Reads the current machine. On non-macOS hosts returns a plausible profile so tests and tools still run.
    public static func current() -> HardwareProfile {
        #if os(macOS)
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let mem = sysctlUInt64("hw.memsize") ?? 8 * 1_073_741_824
        let cpu = Int(sysctlUInt64("hw.ncpu") ?? 8)
        let perf = Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? UInt64(max(cpu / 2, 1)))
        let gpu = gpuCoreCount() ?? 10
        let bw = ChipTable.bandwidth(chip: chip, gpuCores: gpu)
        let wiredMB = sysctlUInt64("iogpu.wired_limit_mb") ?? 0
        let limit: UInt64? = wiredMB > 0 ? wiredMB * 1_048_576 : nil
        return HardwareProfile(chip: chip, memoryBytes: mem, gpuCores: gpu, cpuCores: cpu, performanceCores: perf,
                               bandwidthGBs: bw.gbs, bandwidthIsEstimate: bw.estimate,
                               gpuLimitBytes: limit, availableBytes: availableMemory())
        #else
        let mem = ProcessInfo.processInfo.physicalMemory
        let cpu = ProcessInfo.processInfo.activeProcessorCount
        return HardwareProfile(chip: "Generic (non-macOS)", memoryBytes: mem, gpuCores: 0, cpuCores: cpu,
                               performanceCores: cpu, bandwidthGBs: 50, bandwidthIsEstimate: true)
        #endif
    }

    #if os(macOS)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var small: UInt32 = 0
        var smallSize = MemoryLayout<UInt32>.size
        if sysctlbyname(name, &small, &smallSize, nil, 0) == 0 { return UInt64(small) }
        return nil
    }

    /// GPU core count from the IO registry (`gpu-core-count` on the AGX accelerator).
    static func gpuCoreCount() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-rc", "AGXAccelerator", "-d", "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "\"gpu-core-count\" = ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// free + inactive + purgeable + speculative pages, in bytes.
    public static func availableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return pages * page
    }

    /// Bytes of swap currently in use.
    public static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
    #endif
}
