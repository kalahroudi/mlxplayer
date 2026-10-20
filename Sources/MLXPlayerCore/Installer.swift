import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum InstallStep: Int, CaseIterable, Sendable {
    case checkSystem, installUV, createEnvironment, installMLX

    public var title: String {
        switch self {
        case .checkSystem: return "Check your Mac"
        case .installUV: return "Install uv"
        case .createEnvironment: return "Create Python environment"
        case .installMLX: return "Install mlx-lm"
        }
    }
}

public enum InstallState: Equatable, Sendable {
    case pending, running, done(String), failed(String)
}

public struct InstallEvent: Sendable {
    public var step: InstallStep
    public var state: InstallState
    public var log: String?
}

public enum InstallError: Error, LocalizedError {
    case unsupported(String)
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m), .download(let m): return m
        }
    }
}

/// Installs uv, a private Python, and mlx-lm into the app folder. No admin rights, nothing global.
public final class Installer: @unchecked Sendable {
    public let paths: AppPaths
    private let session: URLSession
    public static let pythonVersion = "3.12"

    public init(paths: AppPaths, session: URLSession = .shared) {
        self.paths = paths
        self.session = session
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: paths.mlxServer.path) }

    static var uvTriple: String? {
        #if os(macOS)
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-gnu"
        #else
        return "x86_64-unknown-linux-gnu"
        #endif
        #else
        return nil
        #endif
    }

    var uvEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["UV_CACHE_DIR"] = paths.uvCache.path
        env["UV_PYTHON_INSTALL_DIR"] = paths.pythonDir.path
        env["UV_NO_PROGRESS"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Runs every step, reporting progress. Already-complete steps are skipped quickly.
    public func run(onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws {
        @Sendable func emit(_ step: InstallStep, _ state: InstallState, _ log: String? = nil) {
            onEvent(InstallEvent(step: step, state: state, log: log))
        }
        func fail(_ step: InstallStep, _ error: Error) -> Error {
            emit(step, .failed(error.localizedDescription), "✗ \(error.localizedDescription)")
            return error
        }

        try paths.ensureDirectories()

        // 1. System check
        emit(.checkSystem, .running)
        #if os(macOS)
        #if arch(arm64)
        let hw = HardwareProbe.current()
        emit(.checkSystem, .done("\(hw.chip) · \(formatBytes(hw.memoryBytes))"), "✓ \(hw.chip), \(formatBytes(hw.memoryBytes)) memory")
        #else
        throw fail(.checkSystem, InstallError.unsupported("MLX needs an Apple Silicon Mac."))
        #endif
        #else
        emit(.checkSystem, .done("Non-macOS host"), "! Not macOS: MLX will not run here, continuing for testing.")
        #endif

        // 2. uv
        emit(.installUV, .running)
        do {
            if !FileManager.default.isExecutableFile(atPath: paths.uv.path) {
                try await downloadUV(log: { emit(.installUV, .running, $0) })
            }
            emit(.installUV, .done("uv ready"), "✓ uv at \(paths.uv.path)")
        } catch { throw fail(.installUV, error) }

        // 3. Python environment
        emit(.createEnvironment, .running)
        do {
            if !FileManager.default.isExecutableFile(atPath: paths.venvPython.path) {
                try await runCommand(paths.uv, ["venv", paths.venv.path, "--python", Self.pythonVersion],
                                     environment: uvEnvironment) { emit(.createEnvironment, .running, $0) }
            }
            emit(.createEnvironment, .done("Python \(Self.pythonVersion)"), "✓ Python environment ready")
        } catch { throw fail(.createEnvironment, error) }

        // 4. mlx-lm
        emit(.installMLX, .running)
        do {
            try await runCommand(paths.uv, ["pip", "install", "--python", paths.venvPython.path, "mlx-lm"],
                                 environment: uvEnvironment) { emit(.installMLX, .running, $0) }
            let version = (try? await installedVersion()) ?? "installed"
            emit(.installMLX, .done("mlx-lm \(version)"), "✓ mlx-lm \(version)")
        } catch { throw fail(.installMLX, error) }
    }

    func downloadUV(log: @escaping @Sendable (String) -> Void) async throws {
        guard let triple = Self.uvTriple else { throw InstallError.unsupported("Unsupported platform") }
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-\(triple).tar.gz")!
        log("Downloading uv (\(triple))…")
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download("uv download failed (HTTP \(http.statusCode))")
        }
        log("Downloaded \(formatBytes(UInt64(data.count)))")

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mlxplayer-uv-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent("uv.tar.gz")
        try data.write(to: archive)
        let extracted = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await runCommand(URL(fileURLWithPath: "/usr/bin/tar"),
                             ["-xzf", archive.path, "-C", extracted.path, "--strip-components=1"],
                             environment: [:]) { log($0) }
        try fm.createDirectory(at: paths.bin, withIntermediateDirectories: true)
        if fm.fileExists(atPath: paths.uv.path) { try fm.removeItem(at: paths.uv) }
        try fm.moveItem(at: extracted.appendingPathComponent("uv"), to: paths.uv)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.uv.path)
    }

    /// Upgrades mlx-lm to the newest release.
    public func upgrade(onLine: @escaping @Sendable (String) -> Void) async throws {
        try await runCommand(paths.uv, ["pip", "install", "--python", paths.venvPython.path, "-U", "mlx-lm"],
                             environment: uvEnvironment, onLine: onLine)
    }

    public func installedVersion() async throws -> String {
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        try await runCommand(paths.venvPython,
                             ["-c", "import importlib.metadata as m; print(m.version('mlx-lm'))"],
                             environment: uvEnvironment) { box.text = $0 }
        return box.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
