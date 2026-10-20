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

    // MARK: Keep after restart

    public static let daemonLabel = "com.mlxplayer.gpulimit"
    public static let daemonPath = "/Library/LaunchDaemons/com.mlxplayer.gpulimit.plist"

    /// Launch daemon that sets the limit at every boot.
    static func daemonPlist(mb: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/sbin/sysctl</string>
                <string>iogpu.wired_limit_mb=\(mb)</string>
            </array>
            <key>RunAtLoad</key><true/>
        </dict>
        </plist>

        """
    }

    /// Shell run as admin: writes the plist (passed as base64, so no quoting problems), loads it, applies the value.
    static func persistScript(mb: Int) -> String {
        let b64 = Data(daemonPlist(mb: mb).utf8).base64EncodedString()
        let p = daemonPath
        return "echo \(b64) | /usr/bin/base64 -D > \(p); /usr/sbin/chown root:wheel \(p); /bin/chmod 644 \(p); "
            + "/bin/launchctl bootout system \(p) 2>/dev/null; /bin/launchctl bootstrap system \(p); /usr/sbin/sysctl iogpu.wired_limit_mb=\(mb)"
    }

    static func removeScript() -> String {
        "/bin/launchctl bootout system \(daemonPath) 2>/dev/null; /bin/rm -f \(daemonPath); /usr/sbin/sysctl iogpu.wired_limit_mb=0"
    }

    /// The limit that will be set at boot, or nil when nothing is kept.
    public static var persistedMB: Int? {
        guard let data = FileManager.default.contents(atPath: daemonPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let last = args.last, last.hasPrefix("iogpu.wired_limit_mb="),
              let mb = Int(last.dropFirst("iogpu.wired_limit_mb=".count)) else { return nil }
        return mb
    }

    /// Applies the limit now and keeps it across restarts.
    public static func persist(mb: Int, totalBytes: UInt64) async throws {
        try validate(mb, totalBytes: totalBytes)
        guard mb > 0 else { return try await removePersistence() }
        try await runAsAdmin(persistScript(mb: mb))
    }

    /// Stops keeping the limit and returns to the macOS default.
    public static func removePersistence() async throws {
        try await runAsAdmin(removeScript())
    }

    private static func runAsAdmin(_ shell: String) async throws {
        try await runOsascript("do shell script \"\(shell)\" with administrator privileges")
    }

    public static func apply(mb: Int, totalBytes: UInt64) async throws {
        try validate(mb, totalBytes: totalBytes)
        try await runOsascript(script(mb: mb))
    }

    private static func runOsascript(_ script: String) async throws {
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
