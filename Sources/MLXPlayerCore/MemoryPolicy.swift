import Foundation

public enum MemoryPressure: Int, Comparable, Codable, Sendable {
    case normal, warning, high, critical

    public static func < (l: MemoryPressure, r: MemoryPressure) -> Bool { l.rawValue < r.rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

public enum MemoryAction: Equatable, Sendable {
    case trimPromptCache(toPercent: Int)
    case capContext(tokens: Int)
    case unloadModel
}

/// Decides what to do as pressure rises. Pure, so it is easy to test.
public enum MemoryPolicy {
    /// macOS only reports normal/warning/critical. "High" is a warning with real swap use.
    public static func level(system: MemoryPressure, swapBytes: UInt64) -> MemoryPressure {
        if system == .warning, swapBytes > 512 * 1_048_576 { return .high }
        return system
    }

    public static func actions(level: MemoryPressure, swapBytes: UInt64, settings: AppSettings) -> [MemoryAction] {
        var out: [MemoryAction] = []
        if level >= .warning, settings.trimCacheOnWarning {
            out.append(.trimPromptCache(toPercent: settings.trimCacheToPercent))
        }
        if level >= .high, settings.capContextOnHigh {
            out.append(.capContext(tokens: settings.cappedContext))
        }
        let swapGB = Double(swapBytes) / 1_073_741_824
        if level >= .critical, settings.unloadOnCritical, swapGB >= settings.criticalSwapGB {
            out.append(.unloadModel)
        }
        return out
    }
}

#if canImport(Darwin)
import Dispatch

/// Reports system memory pressure changes.
public final class MemoryMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    public var onChange: (@Sendable (MemoryPressure) -> Void)?

    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let e = self.source.data
            let level: MemoryPressure = e.contains(.critical) ? .critical : (e.contains(.warning) ? .warning : .normal)
            self.onChange?(level)
        }
        source.resume()
    }

    deinit { source.cancel() }

    /// Maps kern.memorystatus_vm_pressure_level (1 normal, 2 warning, 4 critical).
    public static func pressure(fromKernelLevel level: Int) -> MemoryPressure {
        level >= 4 ? .critical : (level == 2 ? .warning : .normal)
    }

    /// Reads the level directly. The dispatch source above can stay silent (it did under `memory_pressure -l warn`),
    /// so the app also polls this on its timer and treats a change like an event.
    public static func currentLevel() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return pressure(fromKernelLevel: Int(level))
    }
}
#endif
