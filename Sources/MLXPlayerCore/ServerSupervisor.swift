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
///
/// Rules this type keeps, because loading and unloading is where local model tools usually go wrong:
/// - one process at a time; a new start or a stop cancels a start that is still loading
/// - stopping waits until the process (and anything it spawned) is really gone, so its memory is back
/// - the pid is recorded on disk so a crashed app can reap a leftover server on the next launch
/// - "running" means the model answered a request, not just that the port opened
public actor ServerSupervisor {
    private let paths: AppPaths
    private let logs: LogBuffer
    private var process: ManagedProcess?
    private var startedAt: Date?
    /// Bumped by every start and stop; a start that sees it change has been cancelled.
    private var generation = 0
    public private(set) var state: ServerState = .stopped
    public private(set) var activeSettings: ServerSettings?
    public private(set) var backendPort: Int = 0
    private let onState: @Sendable (ServerState) -> Void
    /// Readable from any thread so the app can kill the server synchronously while quitting.
    private let current = CurrentProcess()

    public init(paths: AppPaths, logs: LogBuffer, onState: @escaping @Sendable (ServerState) -> Void) {
        self.paths = paths
        self.logs = logs
        self.onState = onState
    }

    public var uptime: TimeInterval? { startedAt.map { Date().timeIntervalSince($0) } }
    public var processID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    /// Memory the server and its children really use (physical footprint).
    public var footprintBytes: UInt64 { processID.map { ProcessTree.footprint(of: $0) } ?? 0 }

    /// Kills the server immediately. Safe to call from any thread, e.g. when the app is terminating.
    public nonisolated func killNow() { current.process?.killNow(); try? FileManager.default.removeItem(at: paths.serverPidFile) }

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
        for (k, v) in HFToken.environment() { env[k] = v }
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Launches the server on `port` and waits until the model answers a request.
    /// Throws `ServerError.cancelled` if a stop or another start arrives meanwhile.
    public func start(settings: ServerSettings, port: Int, supportedFlags: Set<String>?, customExecutable: String?) async throws {
        generation += 1
        let mine = generation
        if process != nil { await terminateCurrent() }
        guard mine == generation else { throw ServerError.cancelled }

        let exe = executable(custom: customExecutable)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            set(.failed("mlx_lm.server not found. Run setup first."))
            throw ServerError.notInstalled
        }
        guard TCP.isPortFree(port) else {
            set(.failed("Port \(port) is in use by another program."))
            throw ServerError.portBusy(port)
        }
        set(.starting("Loading \(settings.modelID)…"))
        activeSettings = settings
        backendPort = port
        let args = settings.arguments(supported: supportedFlags, portOverride: port)
        logs.append("$ mlx_lm.server " + args.joined(separator: " "))

        let logs = self.logs
        let p = ManagedProcess(executable: exe, arguments: args, environment: environment(extra: settings.environment)) { line in logs.append(line) }
        do { try p.start() } catch {
            set(.failed(error.localizedDescription))
            throw error
        }
        process = p
        current.process = p
        startedAt = Date()
        if let t = ProcessTree.startTime(of: p.processIdentifier) {
            PIDRecord.write(PIDRecord(pid: p.processIdentifier, startTime: t), to: paths.serverPidFile)
        }

        let deadline = Date().addingTimeInterval(900)
        var ready = false
        while Date() < deadline {
            if mine != generation { throw ServerError.cancelled }
            if !p.isRunning { throw await failure(of: p, generation: mine) }
            if !ready, await Self.ready(host: "127.0.0.1", port: port) {
                ready = true
                if mine == generation { set(.starting("Warming up…")) }
            }
            if ready {
                // The model has to answer a real request before we call it running. This surfaces
                // out-of-memory at load time instead of on the user's first request.
                if await Self.warmUp(port: port, alive: { p.isRunning }) {
                    if mine != generation { throw ServerError.cancelled }
                    set(.running)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if mine == generation {
            await terminateCurrent()
            set(.failed("Timed out waiting for the model to load."))
        }
        throw ServerError.timeout
    }

    /// Turns a dead process into the most useful error.
    private func failure(of p: ManagedProcess, generation mine: Int) async -> ServerError {
        let code = await p.waitUntilExit()
        let tail = p.recentOutput.joined(separator: "\n").lowercased()
        let oom = tail.contains("insufficient memory") || tail.contains("outofmemory") || tail.contains("out of memory")
            || tail.contains("memoryerror") || tail.contains("kiogpucommandbuffercallbackerroroutofmemory")
            || (p.diedBySignal && code == SIGKILL)
        if process === p { process = nil; current.process = nil }
        try? FileManager.default.removeItem(at: paths.serverPidFile)
        guard mine == generation else { return .cancelled }
        let error: ServerError = oom ? .outOfMemory : .exited(code)
        set(.failed(error.errorDescription ?? "The server stopped."))
        return error
    }

    private func terminateCurrent() async {
        guard let p = process else { return }
        p.terminate()
        _ = await p.waitUntilExit()
        // Anything the server spawned must be gone too, or its memory stays allocated.
        for c in ProcessTree.descendants(of: p.processIdentifier) where ProcessTree.isAlive(c) { kill(c, SIGKILL) }
        if process === p { process = nil; current.process = nil }
        startedAt = nil
        try? FileManager.default.removeItem(at: paths.serverPidFile)
    }

    public func stop() async {
        generation += 1
        guard process != nil else {
            if state != .stopped { set(.stopped) }
            return
        }
        set(.stopping)
        await terminateCurrent()
        set(.stopped)
    }

    /// Called when the process dies by itself; keeps state honest.
    public func checkAlive() {
        if let p = process, !p.isRunning, state == .running {
            process = nil
            current.process = nil
            try? FileManager.default.removeItem(at: paths.serverPidFile)
            set(.failed("Server stopped unexpectedly. \(p.exitSummary)"))
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

    /// Sends a one-token request. Any HTTP answer counts (embedding and vision models may refuse chat);
    /// a dead connection or a timeout does not.
    static func warmUp(port: Int, alive: @Sendable () -> Bool = { true }) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"stream":false}"#.utf8)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp is HTTPURLResponse
        } catch { return false }
    }
}

final class CurrentProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var _p: ManagedProcess?
    var process: ManagedProcess? {
        get { lock.withLock { _p } }
        set { lock.withLock { _p = newValue } }
    }
}

public enum ServerError: Error, LocalizedError, Equatable {
    case notInstalled, exited(Int32), timeout, cancelled, outOfMemory, portBusy(Int)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "mlx-lm is not installed yet."
        case .exited(let c): return "The server exited with code \(c)."
        case .timeout: return "The model took too long to load."
        case .cancelled: return "Cancelled."
        case .outOfMemory: return "Not enough memory to load this model. Try a smaller or 4-bit version, or a shorter context."
        case .portBusy(let p): return "Port \(p) is in use by another program."
        }
    }
}
