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
    private var exitContinuation: CheckedContinuation<Int32, Never>?
    private var exitCode: Int32?
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
                let cont = self.exitContinuation
                self.exitContinuation = nil
                self.lock.unlock()
                cont?.resume(returning: p.terminationStatus)
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
        lines.forEach(onLine)
    }

    private func flushPending() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onLine(s) }
    }

    /// Asks the process to quit, then kills it if it is still alive after `grace` seconds.
    public func terminate(grace: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if let self, self.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    public func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                cont.resume(returning: code)
            } else {
                exitContinuation = cont
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
                       onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
    let p = ManagedProcess(executable: executable, arguments: arguments, environment: environment, onLine: onLine)
    try p.start()
    let code = await p.waitUntilExit()
    if code != 0 { throw ProcessError.failed(command: executable.lastPathComponent, code: code) }
    return code
}
