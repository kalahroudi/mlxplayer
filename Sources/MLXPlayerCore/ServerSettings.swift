import Foundation

/// Everything configurable about one model's server run. Saved per model.
public struct ServerSettings: Codable, Equatable, Sendable {
    public var modelID: String
    public var host = "127.0.0.1"
    public var port = 8080

    // Context & memory
    public var contextLength = 32_768
    public var promptCacheEnabled = true
    public var promptCacheGB = 8.0
    public var prefillStepSize = 2048
    public var promptConcurrency = 8
    public var decodeConcurrency = 32
    /// KV cache quantization (4 or 8). nil = full precision. mlx-lm serves one request at a time when set.
    public var kvBits: Int?

    // Sampling defaults
    public var temperature = 0.6
    public var topP = 0.95
    public var topK = 20
    public var minP = 0.0
    public var maxTokens = 4096

    // Model options
    public var draftModel: String?
    public var numDraftTokens = 4
    public var chatTemplatePath: String?
    /// JSON object passed to the chat template, e.g. {"enable_thinking": false}.
    public var chatTemplateArgs: String?
    public var adapterPath: String?
    public var trustRemoteCode = false

    // Network & environment
    public var allowedOrigins = "*"
    public var logLevel = "INFO"
    public var environment: [String: String] = [:]
    public var extraArguments = ""

    public init(modelID: String) { self.modelID = modelID }

    /// Arguments for `mlx_lm.server`. Pass the flags the installed version supports so unknown ones are skipped.
    /// `portOverride` is used when the on-demand proxy owns the public port.
    public func arguments(supported: Set<String>? = nil, portOverride: Int? = nil) -> [String] {
        var args: [String] = []
        func ok(_ flag: String) -> Bool { supported?.contains(flag) ?? true }
        func add(_ flag: String, _ value: String?) {
            guard ok(flag) else { return }
            args.append(flag)
            if let value { args.append(value) }
        }

        add("--model", modelID)
        add("--host", host)
        add("--port", String(portOverride ?? port))
        add("--temp", Self.number(temperature))
        add("--top-p", Self.number(topP))
        add("--top-k", String(topK))
        if minP > 0 { add("--min-p", Self.number(minP)) }
        add("--max-tokens", String(maxTokens))
        add("--prefill-step-size", String(prefillStepSize))
        add("--prompt-concurrency", String(promptConcurrency))
        add("--decode-concurrency", String(decodeConcurrency))
        if promptCacheEnabled {
            add("--prompt-cache-bytes", String(UInt64(promptCacheGB * 1_073_741_824)))
        }
        if let bits = kvBits { add("--kv-bits", String(bits)) }
        if let draft = draftModel, !draft.isEmpty {
            add("--draft-model", draft)
            add("--num-draft-tokens", String(numDraftTokens))
        }
        if let path = chatTemplatePath, !path.isEmpty { add("--chat-template", path) }
        if let json = chatTemplateArgs, !json.isEmpty { add("--chat-template-args", json) }
        if let adapter = adapterPath, !adapter.isEmpty { add("--adapter-path", adapter) }
        if trustRemoteCode { add("--trust-remote-code", nil) }
        if allowedOrigins != "*" || supported != nil { add("--allowed-origins", allowedOrigins) }
        add("--log-level", logLevel)
        // Some versions expose a hard KV cap; use it when present.
        if ok("--max-kv-size"), supported != nil { args += ["--max-kv-size", String(contextLength)] }

        let extra = extraArguments.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        args += extra
        return args
    }

    /// Human-readable command, quoting JSON and spaces, for the Command tab.
    public func commandPreview(supported: Set<String>? = nil, executable: String = "mlx_lm.server") -> String {
        let parts = arguments(supported: supported).map { arg -> String in
            if arg.hasPrefix("{") { return "'\(arg)'" }
            return arg.contains(" ") ? "\"\(arg)\"" : arg
        }
        return ([executable] + parts).joined(separator: " ")
    }

    static func number(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// App-wide settings that are not tied to one model.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum Profile: String, Codable, CaseIterable, Sendable { case performance, balanced, saver }
    public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable { case speed, memory, iconOnly }
    public enum AgentPermission: String, Codable, CaseIterable, Sendable { case readOnly, askFirst, fullControl }

    public var profile: Profile = .balanced
    public var menuBarDisplay: MenuBarDisplay = .speed
    public var startServerAtLaunch = false
    public var launchAtLogin = false

    // Look
    public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public var appearance: Appearance = .system
    /// Sidebar shows icons only.
    public var sidebarCollapsed = false

    // On-demand loading
    public var onDemandLoading = true
    public var idleUnloadMinutes = 30
    public var unloadOnSleep = true
    public var unloadOnScreenLock = false
    public var unloadWhenMemoryNeeded = true
    public var preloadAtLogin = false
    /// Use the request's "model" field to load a different installed model on demand.
    public var switchModelsByRequest = true

    // Safeguards
    public var preflightFitCheck = true
    public var autoReduceContext = true
    public var reserveGB = 8.0
    public var lighterOnBattery = false

    // Automatic responses by pressure level
    public var trimCacheOnWarning = true
    public var trimCacheToPercent = 50
    public var capContextOnHigh = true
    public var cappedContext = 16_384
    public var unloadOnCritical = true
    public var criticalSwapGB = 2.0

    // Agents (MCP)
    public var mcpEnabled = true
    public var agentPermission: AgentPermission = .askFirst
    public var largeDownloadGB = 10.0

    // Uses a user-provided mlx_lm.server instead of the managed install.
    public var customServerPath: String?

    public var lastModelID: String?

    // Updates from the repo's main branch
    public var autoCheckUpdates = true

    public init() {}

    /// Applies a profile's preset values.
    public mutating func apply(profile: Profile) {
        self.profile = profile
        switch profile {
        case .performance:
            idleUnloadMinutes = 0
            trimCacheToPercent = 75
            cappedContext = 32_768
        case .balanced:
            idleUnloadMinutes = 30
            trimCacheToPercent = 50
            cappedContext = 16_384
        case .saver:
            idleUnloadMinutes = 5
            trimCacheToPercent = 25
            cappedContext = 8_192
        }
    }
}

/// Reads and writes settings as JSON under the app folder.
public final class SettingsStore: @unchecked Sendable {
    struct Payload: Codable {
        var app = AppSettings()
        var perModel: [String: ServerSettings] = [:]
    }

    private let url: URL
    private var payload = Payload()
    private let lock = NSLock()

    public init(paths: AppPaths) {
        url = paths.settingsFile
        if let data = try? Data(contentsOf: url) { payload = Self.decodeLeniently(data) }
    }

    /// Fills keys missing from an older or hand-edited file with defaults, so new settings never reset old ones.
    static func decodeLeniently(_ data: Data) -> Payload {
        var out = Payload()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return out }
        func merged<T: Codable>(_ stored: Any?, over base: T) -> T {
            guard let stored = stored as? [String: Any],
                  let baseData = try? JSONEncoder().encode(base),
                  var dict = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else { return base }
            for (k, v) in stored { dict[k] = v }
            guard let mergedData = try? JSONSerialization.data(withJSONObject: dict),
                  let value = try? JSONDecoder().decode(T.self, from: mergedData) else { return base }
            return value
        }
        out.app = merged(root["app"], over: AppSettings())
        for (id, raw) in (root["perModel"] as? [String: Any]) ?? [:] {
            out.perModel[id] = merged(raw, over: ServerSettings(modelID: id))
        }
        return out
    }

    public var app: AppSettings {
        get { lock.withLock { payload.app } }
        set { lock.withLock { payload.app = newValue }; save() }
    }

    public func settings(for modelID: String) -> ServerSettings {
        lock.withLock { payload.perModel[modelID] } ?? ServerSettings(modelID: modelID)
    }

    public func save(_ settings: ServerSettings) {
        lock.withLock { payload.perModel[settings.modelID] = settings }
        save()
    }

    private func save() {
        let snapshot = lock.withLock { payload }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Finds which `--flags` the installed `mlx_lm.server` accepts by parsing its help text.
public enum FlagProbe {
    public static func parse(helpText: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"--[a-z][a-z0-9-]*"#) else { return [] }
        let range = NSRange(helpText.startIndex..., in: helpText)
        var flags = Set<String>()
        regex.enumerateMatches(in: helpText, range: range) { m, _, _ in
            if let m, let r = Range(m.range, in: helpText) { flags.insert(String(helpText[r])) }
        }
        return flags
    }
}
