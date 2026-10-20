import Foundation

/// Thread-safe ring buffer of log lines.
public final class LogBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let capacity: Int
    private let lock = NSLock()
    public var onAppend: (@Sendable (String) -> Void)?

    public init(capacity: Int = 2000) { self.capacity = capacity }

    public func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
        onAppend?(line)
    }

    public var snapshot: [String] { lock.withLock { lines } }
    public func clear() { lock.withLock { lines.removeAll() } }
}

/// A child process whose output is delivered line by line.
public final class ManagedProcess: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private var pending = Data()
    private let lock = NSLock()
    private var exitContinuations: [CheckedContinuation<Int32, Never>] = []
    private var exitCode: Int32?
    private var recent: [String] = []
    public private(set) var diedBySignal = false
    private let onLine: @Sendable (String) -> Void

    public init(executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: URL? = nil, onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardOutput = outPipe
        process.standardError = outPipe
        process.standardInput = FileHandle.nullDevice
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flushPending()
                return
            }
            self.consume(data)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Give the reader a moment to drain remaining output.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.flushPending()
                self.lock.lock()
                self.exitCode = p.terminationStatus
                self.diedBySignal = p.terminationReason == .uncaughtSignal
                let waiters = self.exitContinuations
                self.exitContinuations = []
                self.lock.unlock()
                waiters.forEach { $0.resume(returning: p.terminationStatus) }
            }
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        pending.append(data)
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<idx]
            pending.removeSubrange(pending.startIndex...idx)
            if !lineData.isEmpty, let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        lock.unlock()
        lock.withLock { recent.append(contentsOf: lines); if recent.count > 40 { recent.removeFirst(recent.count - 40) } }
        lines.forEach(onLine)
    }

    private func flushPending() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onLine(s) }
    }

    /// Asks the process to quit, then kills it and anything it spawned if it is still alive after `grace` seconds.
    public func terminate(grace: TimeInterval = 5) {
        guard process.isRunning else { killDescendants(); return }
        let pid = process.processIdentifier
        let children = ProcessTree.descendants(of: pid)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if let self, self.process.isRunning { kill(pid, SIGKILL) }
            for c in children where ProcessTree.isAlive(c) { kill(c, SIGKILL) }
        }
    }

    /// Kills right now, without waiting. Used on app quit, where there is no time for a grace period.
    public func killNow() {
        let pid = process.processIdentifier
        let children = ProcessTree.descendants(of: pid)
        if process.isRunning { kill(pid, SIGKILL) }
        for c in children { kill(c, SIGKILL) }
    }

    private func killDescendants() {
        for c in ProcessTree.descendants(of: process.processIdentifier) { kill(c, SIGKILL) }
    }

    /// Last lines of output, for diagnosing a crash.
    public var recentOutput: [String] { lock.withLock { recent } }

    public func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                cont.resume(returning: code)
            } else {
                exitContinuations.append(cont)
                lock.unlock()
            }
        }
    }
}

public enum ProcessError: Error, LocalizedError {
    case failed(command: String, code: Int32)
    public var errorDescription: String? {
        switch self {
        case .failed(let c, let code): return "\(c) exited with code \(code)"
        }
    }
}

/// Runs a command to completion, streaming its output.
@discardableResult
public func runCommand(_ executable: URL, _ arguments: [String], environment: [String: String],
                       workingDirectory: URL? = nil, timeout: TimeInterval? = nil,
                       onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
    let p = ManagedProcess(executable: executable, arguments: arguments, environment: environment,
                           workingDirectory: workingDirectory, onLine: onLine)
    try p.start()
    if let timeout {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate(grace: 1) } }
    }
    let code = await p.waitUntilExit()
    if code != 0 { throw ProcessError.failed(command: executable.lastPathComponent, code: code) }
    return code
}
