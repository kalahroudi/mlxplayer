import Foundation

/// AI agents that can use the mlxplayer MCP server, and how to connect them.
public enum AgentKind: String, CaseIterable, Sendable, Identifiable {
    case claudeCode, claudeDesktop, cursor, windsurf, geminiCLI, codexCLI
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .geminiCLI: "Gemini CLI"
        case .codexCLI: "Codex CLI"
        }
    }

    /// Desktop editors read their MCP config only at launch.
    public var needsRestart: Bool { self == .claudeDesktop || self == .cursor || self == .windsurf }
}

public struct AgentStatus: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notDetected
        case available                    // agent found, MLX Player not connected
        case connected                    // entry present and pointing at the current server
        case outdated(String)             // entry points somewhere else (app moved or renamed)
    }
    public let kind: AgentKind
    public var state: State
    public var id: String { kind.rawValue }
    public var detected: Bool { state != .notDetected }
}

public struct AgentError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum AgentIntegrations {
    public static let serverName = "mlxplayer"

    /// Where the MCP server lives: inside the installed app, or the bundle that is running now.
    public static func serverPath(bundlePath: String = Bundle.main.bundlePath) -> String {
        bundlePath.hasSuffix(".app") ? bundlePath + "/Contents/MacOS/mlxplayer-mcp" : "/Applications/MLX Player.app/Contents/MacOS/mlxplayer-mcp"
    }

    // MARK: Locations

    static func home(_ rel: String) -> URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel) }

    /// JSON config file for agents that keep MCP servers under "mcpServers".
    public static func configURL(_ kind: AgentKind) -> URL? {
        switch kind {
        case .claudeCode: home(".claude.json")
        case .claudeDesktop: home("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor: home(".cursor/mcp.json")
        case .windsurf: home(".codeium/windsurf/mcp_config.json")
        case .geminiCLI: home(".gemini/settings.json")
        case .codexCLI: nil   // TOML, see codexConfigURL
        }
    }
    public static var codexConfigURL: URL { home(".codex/config.toml") }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Is the agent itself on this Mac?
    public static func isDetected(_ kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode: hasCLI("claude") || exists(home(".claude").path)
        case .claudeDesktop: exists("/Applications/Claude.app") || exists(home("Applications/Claude.app").path) || exists(home("Library/Application Support/Claude").path)
        case .cursor: exists("/Applications/Cursor.app") || exists(home("Applications/Cursor.app").path) || exists(home(".cursor").path)
        case .windsurf: exists("/Applications/Windsurf.app") || exists(home(".codeium/windsurf").path)
        case .geminiCLI: hasCLI("gemini") || exists(home(".gemini").path)
        case .codexCLI: hasCLI("codex") || exists(home(".codex").path)
        }
    }

    // MARK: Scan

    public static func scan(serverPath: String = serverPath()) -> [AgentStatus] {
        AgentKind.allCases.map { kind in
            guard isDetected(kind) else { return AgentStatus(kind: kind, state: .notDetected) }
            let commands: [String]
            switch kind {
            case .codexCLI: commands = codexCommand().map { [$0] } ?? []
            case .claudeCode: commands = claudeCodeCommands()
            default: commands = configURL(kind).flatMap { jsonCommand(at: $0) }.map { [$0] } ?? []
            }
            if commands.isEmpty { return AgentStatus(kind: kind, state: .available) }
            if commands.contains(serverPath) { return AgentStatus(kind: kind, state: .connected) }
            return AgentStatus(kind: kind, state: .outdated(commands[0]))
        }
    }

    // MARK: JSON configs

    /// The command registered in a JSON config's top-level "mcpServers", if any.
    public static func jsonCommand(at url: URL) -> String? {
        guard let root = readObject(url) else { return nil }
        return command(in: root)
    }

    private static func command(in container: [String: Any]) -> String? {
        ((container["mcpServers"] as? [String: Any])?[serverName] as? [String: Any])?["command"] as? String
    }

    /// Claude Code keeps servers per scope: user level and under each project.
    static func claudeCodeCommands(at url: URL = configURL(.claudeCode)!) -> [String] {
        guard let root = readObject(url) else { return [] }
        var found = [command(in: root)].compactMap { $0 }
        for (_, project) in (root["projects"] as? [String: Any]) ?? [:] {
            if let c = (project as? [String: Any]).flatMap({ command(in: $0) }) { found.append(c) }
        }
        return found
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Adds (or updates) the entry and keeps everything else in the file. A one-time backup is kept next to it.
    public static func jsonInstall(at url: URL, command: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError(message: "\(url.path) is not a JSON object, so it was left unchanged.")
            }
            root = obj
            let backup = url.appendingPathExtension("mlxplayer-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": command]
        root["mcpServers"] = servers
        try write(root, to: url)
    }

    public static func jsonRemove(at url: URL) throws {
        guard let data = try? Data(contentsOf: url), var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any], servers[serverName] != nil else { return }
        servers.removeValue(forKey: serverName)
        root["mcpServers"] = servers
        try write(root, to: url)
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // MARK: Codex (TOML)

    /// The command of [mcp_servers.mlxplayer] in Codex's config.toml, if present.
    public static func codexCommand(at url: URL = codexConfigURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[mcp_servers.\(serverName)]"; continue }
            if inSection, line.hasPrefix("command"), let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                return String(line[line.index(after: q1)..<q2])
            }
        }
        return nil
    }

    // MARK: Install / remove

    /// Connects an agent. Uses the agent's own CLI where it has one, otherwise edits its config file.
    public static func install(_ kind: AgentKind, serverPath: String = serverPath()) async throws {
        guard FileManager.default.isExecutableFile(atPath: serverPath) else {
            throw AgentError(message: "The MCP server was not found at \(serverPath). Install MLX Player into Applications first.")
        }
        let exe = quote(serverPath)
        switch kind {
        case .claudeCode:
            if hasCLI("claude") {
                _ = try? await shell("claude mcp remove \(serverName) -s local; claude mcp remove \(serverName) -s user")
                try await shell("claude mcp add -s user \(serverName) -- \(exe)")
            } else { try jsonInstall(at: configURL(kind)!, command: serverPath) }
        case .codexCLI:
            guard hasCLI("codex") else { throw AgentError(message: "The codex command was not found.") }
            _ = try? await shell("codex mcp remove \(serverName)")
            try await shell("codex mcp add \(serverName) -- \(exe)")
        default:
            try jsonInstall(at: configURL(kind)!, command: serverPath)
        }
    }

    public static func remove(_ kind: AgentKind) async throws {
        switch kind {
        case .claudeCode:
            if hasCLI("claude") { try await shell("claude mcp remove \(serverName) -s local; claude mcp remove \(serverName) -s user") }
            else { try jsonRemove(at: configURL(kind)!) }
        case .codexCLI: try await shell("codex mcp remove \(serverName)")
        default: try jsonRemove(at: configURL(kind)!)
        }
    }

    // MARK: Shell

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Is `name` on the PATH of a login shell, which matches the user's terminal?
    static func hasCLI(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Runs a command through a login shell and throws with its output when it fails.
    @discardableResult
    static func shell(_ command: String) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0 else { throw AgentError(message: out.isEmpty ? "Command failed (\(p.terminationStatus))." : out) }
            return out
        }.value
    }
}
