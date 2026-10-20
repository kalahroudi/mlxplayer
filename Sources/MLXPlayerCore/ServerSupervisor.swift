import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ServerState: Equatable, Sendable {
    case stopped
    case starting(String)
    case running
    case stopping
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .starting, .running: return true
        default: return false
        }
    }
}

/// Starts, watches and stops one `mlx_lm.server` process.
public actor ServerSupervisor {
    private let paths: AppPaths
    private let logs: LogBuffer
    private var process: ManagedProcess?
    private var startedAt: Date?
    public private(set) var state: ServerState = .stopped
    public private(set) var activeSettings: ServerSettings?
    public private(set) var backendPort: Int = 0
    private let onState: @Sendable (ServerState) -> Void

    public init(paths: AppPaths, logs: LogBuffer, onState: @escaping @Sendable (ServerState) -> Void) {
        self.paths = paths
        self.logs = logs
        self.onState = onState
    }

    public var uptime: TimeInterval? { startedAt.map { Date().timeIntervalSince($0) } }
    public var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    private func set(_ s: ServerState) {
        state = s
        onState(s)
    }

    public func executable(custom: String?) -> URL {
        if let custom, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return paths.mlxServer
    }

    /// Reads `--help` of the installed server to learn which flags exist.
    public func probeFlags(custom: String?) async -> Set<String>? {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let exe = executable(custom: custom)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return nil }
        _ = try? await runCommand(exe, ["--help"], environment: environment(extra: [:])) { box.lines.append($0) }
        let flags = FlagProbe.parse(helpText: box.lines.joined(separator: "\n"))
        return flags.isEmpty ? nil : flags
    }

    func environment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.venvBin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Launches the server on `port` and waits until it answers requests.
    public func start(settings: ServerSettings, port: Int, supportedFlags: Set<String>?, customExecutable: String?) async throws {
        if state.isActive { await stop() }
        let exe = executable(custom: customExecutable)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            let msg = "mlx_lm.server not found. Run setup first."
            set(.failed(msg))
            throw ServerError.notInstalled
        }
        set(.starting("Loading \(settings.modelID)…"))
        activeSettings = settings
        backendPort = port
        logs.append("$ mlx_lm.server " + settings.arguments(supported: supportedFlags, portOverride: port).joined(separator: " "))

        let logs = self.logs
        let p = ManagedProcess(executable: exe,
                               arguments: settings.arguments(supported: supportedFlags, portOverride: port),
                               environment: environment(extra: settings.environment)) { line in logs.append(line) }
        do { try p.start() } catch {
            set(.failed(error.localizedDescription))
            throw error
        }
        process = p
        startedAt = Date()

        // Wait for readiness, or for the process to die.
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if !p.isRunning {
                let code = await p.waitUntilExit()
                process = nil
                let msg = "Server exited with code \(code) while loading."
                set(.failed(msg))
                throw ServerError.exited(code)
            }
            if await Self.ready(host: "127.0.0.1", port: port) {
                set(.running)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        p.terminate()
        process = nil
        set(.failed("Timed out waiting for the model to load."))
        throw ServerError.timeout
    }

    public func stop() async {
        guard let p = process else { set(.stopped); return }
        set(.stopping)
        p.terminate()
        _ = await p.waitUntilExit()
        process = nil
        startedAt = nil
        set(.stopped)
    }

    /// Called when the process dies by itself; keeps state honest.
    public func checkAlive() {
        if let p = process, !p.isRunning, state == .running {
            process = nil
            set(.failed("Server stopped unexpectedly."))
        }
    }

    static func ready(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}

public enum ServerError: Error, LocalizedError {
    case notInstalled, exited(Int32), timeout

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "mlx-lm is not installed yet."
        case .exited(let c): return "The server exited with code \(c)."
        case .timeout: return "The model took too long to load."
        }
    }
}
