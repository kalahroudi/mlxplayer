import Foundation

/// Every file the app owns lives under one folder, so uninstalling is deleting it.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            #if os(macOS)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("MLX Player", isDirectory: true)
            #else
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/mlxplayer", isDirectory: true)
            #endif
        }
    }

    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var uv: URL { bin.appendingPathComponent("uv") }
    public var uvCache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var pythonDir: URL { root.appendingPathComponent("python", isDirectory: true) }
    public var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    public var venvBin: URL { venv.appendingPathComponent("bin", isDirectory: true) }
    public var venvPython: URL { venvBin.appendingPathComponent("python") }
    public var mlxServer: URL { venvBin.appendingPathComponent("mlx_lm.server") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var serverPidFile: URL { root.appendingPathComponent("server.pid") }
    public var usageFile: URL { root.appendingPathComponent("usage.jsonl") }
    public var controlFile: URL { root.appendingPathComponent("control.json") }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// Hugging Face cache, honouring the usual environment overrides.
    public var hfHub: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"] { return URL(fileURLWithPath: hub, isDirectory: true) }
        if let home = env["HF_HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    public func ensureDirectories() throws {
        for dir in [root, bin, uvCache, pythonDir, logsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
