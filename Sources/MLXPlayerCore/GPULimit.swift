import Foundation

/// Sets `iogpu.wired_limit_mb`, the memory the GPU may wire. Needs admin rights, so the change goes
/// through the standard macOS password prompt. It lasts until restart; 0 restores the macOS default.
public enum GPULimit {
    public enum LimitError: Error, LocalizedError, Equatable {
        case outOfRange(maxMB: Int)
        case cancelled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .outOfRange(let m): return "Pick a value up to \(m) MB"
            case .cancelled: return "Cancelled"
            case .failed(let s): return s
            }
        }
    }

    /// Highest value we allow: total memory minus a floor that keeps macOS usable.
    public static func maxMB(totalBytes: UInt64) -> Int {
        let total = Int(totalBytes / 1_048_576)
        return max(0, total - 4096)
    }

    /// Suggested limit: 90% of memory, never above `maxMB`.
    public static func suggestedMB(totalBytes: UInt64) -> Int {
        min(Int(Double(totalBytes) * 0.9 / 1_048_576), maxMB(totalBytes: totalBytes))
    }

    public static func validate(_ mb: Int, totalBytes: UInt64) throws {
        let m = maxMB(totalBytes: totalBytes)
        guard mb == 0 || (mb >= 4096 && mb <= m) else { throw LimitError.outOfRange(maxMB: m) }
    }

    /// The AppleScript that runs sysctl as admin. Only an integer is ever interpolated.
    static func script(mb: Int) -> String {
        "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=\(mb)\" with administrator privileges"
    }

    public static func apply(mb: Int, totalBytes: UInt64) async throws {
        try validate(mb, totalBytes: totalBytes)
        let script = script(mb: mb)
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let pipe = Pipe()
            p.standardError = pipe; p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if out.contains("-128") || out.lowercased().contains("user canceled") { throw LimitError.cancelled }
            throw LimitError.failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
