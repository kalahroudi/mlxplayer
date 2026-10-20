import Foundation

public struct InstalledModel: Identifiable, Equatable, Sendable {
    public var id: String { meta.id }
    public var meta: ModelMetadata
    public var path: URL
    public var sizeBytes: UInt64
}

/// Reads models already in the Hugging Face cache.
public enum ModelLibrary {
    public static func repoDirectory(hub: URL, id: String) -> URL {
        hub.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    public static func scan(hub: URL) -> [InstalledModel] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: hub, includingPropertiesForKeys: nil) else { return [] }
        var out: [InstalledModel] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix("models--") {
            let id = String(dir.lastPathComponent.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            let snapshots = dir.appendingPathComponent("snapshots", isDirectory: true)
            guard let revs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
                  let rev = revs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) })
            else { continue }
            // Skip partial downloads.
            if directorySize(dir.appendingPathComponent("blobs"), suffix: ".incomplete") > 0 { continue }

            var meta = ModelMetadata.fromName(id)
            if let data = try? Data(contentsOf: rev.appendingPathComponent("config.json")),
               let cfg = ModelConfig.parse(data) {
                meta = meta.applying(config: cfg)
            }
            let size = directorySize(dir.appendingPathComponent("blobs"))
            meta.diskBytes = size
            out.append(InstalledModel(meta: meta, path: dir, sizeBytes: size))
        }
        return out.sorted { $0.meta.id < $1.meta.id }
    }

    /// Downloads that were started but never finished (stopped, crashed, or app quit). Resumable with `hf download`.
    public static func scanPartials(hub: URL) -> [PartialModel] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: hub, includingPropertiesForKeys: nil) else { return [] }
        var out: [PartialModel] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix("models--") {
            let blobs = dir.appendingPathComponent("blobs", isDirectory: true)
            let bytes = directorySize(blobs)
            guard bytes > 0 else { continue }
            let snapshots = dir.appendingPathComponent("snapshots", isDirectory: true)
            let hasConfig = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil))?
                .contains { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) } ?? false
            if hasConfig && directorySize(blobs, suffix: ".incomplete") == 0 { continue }
            let id = String(dir.lastPathComponent.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            out.append(PartialModel(id: id, bytes: bytes))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Bytes under a folder; with `suffix`, only files ending in it.
    public static func directorySize(_ url: URL, suffix: String? = nil) -> UInt64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for f in files {
            if let suffix, !f.lastPathComponent.hasSuffix(suffix) { continue }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(size)
        }
        return total
    }

    public static func delete(hub: URL, id: String) throws {
        try FileManager.default.removeItem(at: repoDirectory(hub: hub, id: id))
    }
}

public struct PartialModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var bytes: UInt64
}

public struct DownloadProgress: Equatable, Sendable {
    public var modelID: String
    public var downloadedBytes: UInt64
    public var totalBytes: UInt64?
    public var bytesPerSecond: Double
    public var finished = false
    public var failed: String?

    public init(modelID: String, downloadedBytes: UInt64, totalBytes: UInt64?, bytesPerSecond: Double,
                finished: Bool = false, failed: String? = nil) {
        self.modelID = modelID; self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond
        self.finished = finished; self.failed = failed
    }

    public var fraction: Double {
        guard let t = totalBytes, t > 0 else { return 0 }
        return min(Double(downloadedBytes) / Double(t), 1)
    }

    public var secondsRemaining: Double? {
        guard let t = totalBytes, bytesPerSecond > 1 else { return nil }
        return Double(t - min(downloadedBytes, t)) / bytesPerSecond
    }
}

/// Downloads one model with the `hf` CLI from the managed environment and reports progress
/// by watching the cache folder grow. Pausing stops the process; resuming picks up partial files.
public final class ModelDownload: @unchecked Sendable {
    public let modelID: String
    private let paths: AppPaths
    private let totalBytes: UInt64?
    private var process: ManagedProcess?
    private var timer: DispatchSourceTimer?
    private var lastBytes: UInt64 = 0
    private var lastTime = Date()
    private var smoothed: Double = 0
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let onLog: @Sendable (String) -> Void
    private var cancelled = false
    private let lock = NSLock()
    /// Seconds without a single new byte before the transfer is restarted (it resumes from partial files).
    private let stallLimit: TimeInterval = 45
    private var lastGrowth = Date()
    private var restarts = 0

    public init(modelID: String, paths: AppPaths, totalBytes: UInt64?,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void,
                onLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.modelID = modelID
        self.paths = paths
        self.totalBytes = totalBytes
        self.onProgress = onProgress
        self.onLog = onLog
    }

    private var cacheDir: URL { ModelLibrary.repoDirectory(hub: paths.hfHub, id: modelID).appendingPathComponent("blobs") }

    private func cliURL() -> URL? {
        for name in ["hf", "huggingface-cli"] {
            let url = paths.venvBin.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func start() throws {
        guard let cli = cliURL() else { throw ServerError.notInstalled }
        lock.withLock { cancelled = false }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = paths.venvBin.path + ":" + (env["PATH"] ?? "")
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        for (k, v) in HFToken.environment() { env[k] = v }
        // After a stalled attempt, fall back from the Xet transfer backend to plain HTTP.
        if restarts > 0 { env["HF_HUB_DISABLE_XET"] = "1" }
        lastGrowth = Date()
        let onLog = self.onLog
        let p = ManagedProcess(executable: cli, arguments: ["download", modelID], environment: env) { onLog($0) }
        try p.start()
        process = p
        lastBytes = ModelLibrary.directorySize(cacheDir)
        lastTime = Date()
        startTimer()
        Task { [weak self] in
            let code = await p.waitUntilExit()
            self?.processExited(p, code: code)
        }
    }

    /// A process we killed ourselves to restart a stall must not be reported as a failure.
    private var restarting = false

    private func processExited(_ p: ManagedProcess, code: Int32) {
        let again = lock.withLock { () -> Bool in
            let r = restarting && process === p
            if r { restarting = false }
            return r
        }
        if again {
            timer?.cancel(); timer = nil
            restarts += 1
            onLog("Download stalled; retrying (attempt \(restarts + 1)).")
            do { try start() } catch { finish(exitCode: 1) }
            return
        }
        finish(exitCode: code)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        let bytes = ModelLibrary.directorySize(cacheDir)
        let dt = now.timeIntervalSince(lastTime)
        if dt > 0 {
            let instant = Double(bytes >= lastBytes ? bytes - lastBytes : 0) / dt
            smoothed = smoothed == 0 ? instant : smoothed * 0.7 + instant * 0.3
        }
        if bytes > lastBytes { lastGrowth = now }
        else if now.timeIntervalSince(lastGrowth) > stallLimit, restarts < 5, let p = process {
            let go = lock.withLock { () -> Bool in
                if restarting || cancelled { return false }
                restarting = true
                return true
            }
            if go { p.terminate(grace: 2) }
        }
        lastBytes = bytes
        lastTime = now
        onProgress(DownloadProgress(modelID: modelID, downloadedBytes: bytes, totalBytes: totalBytes, bytesPerSecond: smoothed))
    }

    private func finish(exitCode: Int32) {
        timer?.cancel()
        timer = nil
        let wasCancelled = lock.withLock { cancelled }
        if wasCancelled { return }
        let bytes = ModelLibrary.directorySize(cacheDir)
        if exitCode == 0 {
            onProgress(DownloadProgress(modelID: modelID, downloadedBytes: bytes, totalBytes: totalBytes ?? bytes,
                                        bytesPerSecond: 0, finished: true))
        } else {
            onProgress(DownloadProgress(modelID: modelID, downloadedBytes: bytes, totalBytes: totalBytes,
                                        bytesPerSecond: 0, failed: "Download stopped (exit code \(exitCode))."))
        }
    }

    /// Stops the transfer. Partial files stay, so `start()` resumes.
    public func pause() {
        lock.withLock { cancelled = true }
        timer?.cancel()
        timer = nil
        process?.terminate(grace: 2)
    }

    /// Stops and removes the partial download.
    public func cancel() {
        pause()
        try? FileManager.default.removeItem(at: ModelLibrary.repoDirectory(hub: paths.hfHub, id: modelID))
    }
}
