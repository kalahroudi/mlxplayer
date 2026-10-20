import SwiftUI
import AppKit
import MLXPlayerCore
import Darwin

/// One place that owns everything long-lived: the server, the proxy, downloads and settings.
@MainActor @Observable
final class AppModel {
    // MARK: Services
    let paths = AppPaths()
    let store: SettingsStore
    let usage: UsageStore
    let logs = LogBuffer(capacity: 2000)
    let hf = HuggingFaceClient()
    let installer: Installer
    private(set) var supervisor: ServerSupervisor!
    private var proxy: LazyProxy?
    private var control: ControlServer?
    private var memoryMonitor: MemoryMonitor?
    private var downloadsByID: [String: ModelDownload] = [:]
    private var loadTask: Task<Bool, Never>?
    private var timer: Timer?
    private var lastSpeed: (value: Double, at: Date)?
    /// Readable from the proxy's threads without hopping to the main actor.
    private let runningFlag = AtomicFlag()

    // MARK: Settings
    var app: AppSettings {
        didSet { store.app = app; proxy?.contextLimit = effectiveContextLimit }
    }
    var draft: ServerSettings
    private(set) var applied: ServerSettings?

    // MARK: Install
    var isInstalled = false
    var installing = false
    var installStates: [InstallStep: InstallState] = [:]
    var installLog: [String] = []
    var installedVersion: String?
    var showSetup = false

    // MARK: Server
    var serverState: ServerState = .stopped
    var activeModelID: String?
    var supportedFlags: Set<String>?
    var activeRequests = 0
    var proxyError: String?
    var lastError: String?
    var uptime: TimeInterval = 0

    // MARK: Live stats
    var hardware = HardwareProbe.current()
    var tokensPerSecond: Double = 0
    var requestsToday = 0
    var serverMemoryBytes: UInt64 = 0
    var memoryPressure: MemoryPressure = .normal
    var swapBytes: UInt64 = 0
    var pressureHistory: [Double] = []
    var speedHistory: [Double] = []
    var memoryEvents: [(time: Date, text: String)] = []
    private var pressureCapActive = false

    // MARK: Library & downloads
    var installed: [InstalledModel] = []
    var downloads: [String: DownloadProgress] = [:]

    // MARK: Discover
    var searchText = ""
    var searchSort: SearchSort = .downloads
    var filter = ModelFilter()
    var publisher: String? = "mlx-community"
    var results: [ModelMetadata] = []
    var searching = false
    var searchError: String?

    // MARK: Advisor
    var advisorTask: AdvisorTask = .coding
    var advisorVariant: ModelVariant = .standard
    var advisorDescription = ""
    var recommendations: Recommendations?
    var comparison: [Assessment] = []
    var advisorBusy = false
    var advisorError: String?

    // MARK: Usage
    var usageRange: UsageRange = .today
    var usageSummary = UsageSummary()
    var logLines: [String] = []

    init() {
        let store = SettingsStore(paths: paths)
        self.store = store
        self.usage = UsageStore(url: paths.usageFile)
        self.installer = Installer(paths: paths)
        self.app = store.app
        self.draft = ServerSettings(modelID: store.app.lastModelID ?? "")
        self.isInstalled = installer.isInstalled || (store.app.customServerPath != nil)
        self.supervisor = ServerSupervisor(paths: paths, logs: logs) { [weak self] state in
            Task { @MainActor in self?.handle(state: state) }
        }
        logs.onAppend = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 1500 { self.logLines.removeFirst(self.logLines.count - 1500) }
            }
        }
    }

    // MARK: Lifecycle

    func launch() {
        guard timer == nil else { return }
        refreshInstalled()
        if !isInstalled { showSetup = true }
        if let id = app.lastModelID { select(model: id) }
        startProxy()
        startControlServer()
        startMemoryMonitor()
        observeSystemEvents()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refreshVersion() }
        if app.startServerAtLaunch || app.preloadAtLogin, let id = app.lastModelID {
            Task { await startServer(model: id) }
        }
    }

    func refreshVersion() async {
        guard installer.isInstalled else { return }
        installedVersion = try? await installer.installedVersion()
    }

    private func handle(state: ServerState) {
        serverState = state
        runningFlag.value = (state == .running)
        if case .failed(let message) = state { lastError = message }
        if state == .stopped || state == .stopping { uptime = 0 }
    }

    // MARK: Derived

    var isRunning: Bool { serverState == .running }
    var publicPort: Int { draft.port }
    var endpoint: String { "http://\(draft.host == "0.0.0.0" ? "127.0.0.1" : draft.host):\(draft.port)/v1" }
    var advisor: Advisor { Advisor(hardware: hardware, reserveBytes: UInt64(app.reserveGB * 1_073_741_824)) }

    var effectiveContextLimit: Int {
        var limit = applied?.contextLength ?? draft.contextLength
        if pressureCapActive { limit = min(limit, app.cappedContext) }
        return limit
    }

    var activeMeta: ModelMetadata? {
        guard let id = activeModelID ?? app.lastModelID else { return nil }
        return installed.first { $0.id == id }?.meta ?? ModelMetadata.fromName(id)
    }

    var menuBarText: String? {
        switch app.menuBarDisplay {
        case .iconOnly: return nil
        case .speed:
            if case .starting = serverState { return "Loading…" }
            return isRunning && tokensPerSecond > 0.5 ? String(format: "%.0f t/s", tokensPerSecond) : nil
        case .memory:
            return isRunning ? formatBytes(serverMemoryBytes) : nil
        }
    }

    /// Human-readable list of differences between the running server and the draft.
    var pendingChanges: [String] {
        guard let a = applied, a.modelID == draft.modelID, isRunning else { return [] }
        var out: [String] = []
        if a.contextLength != draft.contextLength { out.append("context \(formatContext(a.contextLength)) → \(formatContext(draft.contextLength))") }
        if a.temperature != draft.temperature { out.append("temperature \(a.temperature) → \(draft.temperature)") }
        if a.topP != draft.topP || a.topK != draft.topK || a.minP != draft.minP { out.append("sampling") }
        if a.maxTokens != draft.maxTokens { out.append("max tokens") }
        if a.draftModel != draft.draftModel || a.numDraftTokens != draft.numDraftTokens { out.append("draft model") }
        if a.chatTemplateArgs != draft.chatTemplateArgs || a.chatTemplatePath != draft.chatTemplatePath { out.append("chat template") }
        if a.kvBits != draft.kvBits || a.promptCacheGB != draft.promptCacheGB || a.promptCacheEnabled != draft.promptCacheEnabled { out.append("prompt cache") }
        if a.prefillStepSize != draft.prefillStepSize || a.promptConcurrency != draft.promptConcurrency
            || a.decodeConcurrency != draft.decodeConcurrency { out.append("concurrency") }
        if a.adapterPath != draft.adapterPath || a.trustRemoteCode != draft.trustRemoteCode { out.append("model options") }
        if a.host != draft.host || a.port != draft.port || a.allowedOrigins != draft.allowedOrigins
            || a.environment != draft.environment || a.extraArguments != draft.extraArguments { out.append("network") }
        return out
    }

    var currentAssessment: Assessment? {
        guard !draft.modelID.isEmpty else { return nil }
        let meta = installed.first { $0.id == draft.modelID }?.meta ?? ModelMetadata.fromName(draft.modelID)
        return advisor.assess(meta, task: .coding)
    }

    // MARK: Model selection & settings

    func select(model id: String) {
        draft = store.settings(for: id)
        app.lastModelID = id
    }

    func saveDraft() {
        guard !draft.modelID.isEmpty else { return }
        store.save(draft)
    }

    func applyAndRestart() async {
        saveDraft()
        await startServer(model: draft.modelID)
    }

    func revertDraft() {
        if let a = applied { draft = a } else { draft = store.settings(for: draft.modelID) }
    }

    // MARK: Install

    func runSetup() async {
        installing = true
        installLog = []
        installStates = [:]
        let box = self
        do {
            try await installer.run { event in
                Task { @MainActor in
                    box.installStates[event.step] = event.state
                    if let line = event.log { box.installLog.append(line); if box.installLog.count > 400 { box.installLog.removeFirst() } }
                }
            }
            isInstalled = true
            await refreshVersion()
            supportedFlags = nil
        } catch {
            installLog.append("✗ \(error.localizedDescription)")
        }
        installing = false
    }

    func finishSetup() { showSetup = false }

    /// Points the app at a user-provided mlx_lm.server instead of the managed install.
    func useExisting(server path: String) {
        app.customServerPath = path
        isInstalled = true
        supportedFlags = nil
    }

    func upgradeMLX() async {
        installing = true
        installLog = []
        let box = self
        do {
            try await installer.upgrade { line in Task { @MainActor in box.installLog.append(line) } }
            await refreshVersion()
            supportedFlags = nil
        } catch { installLog.append("✗ \(error.localizedDescription)") }
        installing = false
    }

    // MARK: Server control

    private func startProxy() {
        proxy?.stop()
        let p = LazyProxy(host: "127.0.0.1", port: draft.port > 0 ? draft.port : 8080)
        p.contextLimit = effectiveContextLimit
        p.servedModel = app.lastModelID ?? ""
        p.isBackendRunning = { [flag = runningFlag] in flag.value }
        p.ensureBackend = { [weak self] requested in await self?.ensureLoaded(for: requested) ?? false }
        p.onRecord = { [weak self] record in Task { @MainActor in self?.record(record) } }
        p.onActiveChanged = { [weak self] n in Task { @MainActor in self?.activeRequests = n } }
        do {
            try p.start()
            proxy = p
            proxyError = nil
        } catch {
            proxy = nil
            proxyError = "Port \(draft.port) is busy. Pick another in Server → Network."
        }
    }

    private func record(_ r: UsageRecord) {
        usage.record(r)
        let gen = Double(r.durationMs - (r.firstTokenMs ?? 0)) / 1000
        if r.tokensOut > 0, gen > 0.05 { lastSpeed = (Double(r.tokensOut) / gen, Date()) }
        refreshUsage()
    }

    /// Starts `model` (or the saved one) on the internal port behind the proxy.
    func startServer(model: String? = nil) async {
        let id = model ?? draft.modelID
        guard !id.isEmpty else { lastError = "Pick a model first."; return }
        guard isInstalled else { showSetup = true; return }
        lastError = nil

        var settings = store.settings(for: id)
        if draft.modelID == id { settings = draft }
        let meta = installed.first { $0.id == id }?.meta ?? ModelMetadata.fromName(id)
        let assessment = advisor.assess(meta, task: .coding)
        if app.preflightFitCheck, assessment.verdict == .wontFit {
            lastError = "\(meta.displayName) won't fit in \(formatBytes(advisor.budgetBytes)). Try a smaller model or quantization."
            return
        }
        if app.autoReduceContext, assessment.safeMaxContext > 0, settings.contextLength > assessment.safeMaxContext {
            logs.append("Context reduced from \(formatContext(settings.contextLength)) to \(formatContext(assessment.safeMaxContext)) to fit memory.")
            settings.contextLength = assessment.safeMaxContext
        }

        if proxy == nil || proxy?.port != settings.port { draft.port = settings.port; startProxy() }
        let backendPort = settings.port + 1
        proxy?.backendPort = backendPort
        proxy?.servedModel = id
        if supportedFlags == nil { supportedFlags = await supervisor.probeFlags(custom: app.customServerPath) }

        activeModelID = id
        app.lastModelID = id
        store.save(settings)
        if draft.modelID == id { draft = settings }
        do {
            try await supervisor.start(settings: settings, port: backendPort, supportedFlags: supportedFlags,
                                       customExecutable: app.customServerPath)
            applied = settings
            proxy?.contextLimit = effectiveContextLimit
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopServer() async {
        await supervisor.stop()
        applied = nil
    }

    func restartServer() async {
        if let id = activeModelID ?? app.lastModelID { await startServer(model: id) }
    }

    /// Used by the proxy: load on demand, one start at a time.
    func ensureLoaded(for requested: String?) async -> Bool {
        if isRunning, requested == nil || requested == activeModelID || !app.switchModelsByRequest || !isInstalledModel(requested) {
            return true
        }
        if let task = loadTask { return await task.value }
        guard app.onDemandLoading else { return isRunning }
        var target = activeModelID ?? app.lastModelID
        if app.switchModelsByRequest, let r = requested, isInstalledModel(r) { target = r }
        guard let target else { return false }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            await self.startServer(model: target)
            return self.isRunning
        }
        loadTask = task
        let ok = await task.value
        loadTask = nil
        return ok
    }

    private func isInstalledModel(_ id: String?) -> Bool {
        guard let id else { return false }
        return installed.contains { $0.id == id }
    }

    // MARK: Library

    func refreshInstalled() {
        installed = ModelLibrary.scan(hub: paths.hfHub)
    }

    func delete(model id: String) {
        try? ModelLibrary.delete(hub: paths.hfHub, id: id)
        refreshInstalled()
    }

    func reveal(model id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([ModelLibrary.repoDirectory(hub: paths.hfHub, id: id)])
    }

    // MARK: Downloads

    func download(_ meta: ModelMetadata) {
        let id = meta.id
        guard downloadsByID[id] == nil else { return }
        let total = meta.diskBytes > 0 ? meta.diskBytes : nil
        let dl = ModelDownload(modelID: id, paths: paths, totalBytes: total, onProgress: { [weak self] p in
            Task { @MainActor in self?.downloadUpdate(p) }
        }, onLog: { [weak self] line in self?.logs.append(line) })
        downloadsByID[id] = dl
        downloads[id] = DownloadProgress(modelID: id, downloadedBytes: 0, totalBytes: total, bytesPerSecond: 0)
        do { try dl.start() } catch {
            downloads[id]?.failed = error.localizedDescription
            downloadsByID[id] = nil
        }
        Task {
            if let exact = await hf.repoSize(id) {
                downloads[id]?.totalBytes = exact
            }
        }
    }

    private func downloadUpdate(_ p: DownloadProgress) {
        var q = p
        if q.totalBytes == nil || (downloads[p.modelID]?.totalBytes ?? 0) > (q.totalBytes ?? 0) {
            q.totalBytes = downloads[p.modelID]?.totalBytes
        }
        downloads[p.modelID] = q
        if p.finished || p.failed != nil {
            downloadsByID[p.modelID] = nil
            if p.finished { refreshInstalled() }
            if p.finished {
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); downloads[p.modelID] = nil }
            }
        }
    }

    func pauseDownload(_ id: String) {
        downloadsByID[id]?.pause()
        downloadsByID[id] = nil
        downloads[id]?.bytesPerSecond = 0
        downloads[id]?.failed = "Paused"
    }

    func resumeDownload(_ meta: ModelMetadata) {
        downloads[meta.id] = nil
        download(meta)
    }

    func cancelDownload(_ id: String) {
        downloadsByID[id]?.cancel()
        downloadsByID[id] = nil
        downloads[id] = nil
    }

    // MARK: Search

    func search() async {
        searching = true
        searchError = nil
        defer { searching = false }
        var q = SearchQuery(text: searchText, publisher: publisher, sort: searchSort, variant: filter.variant, limit: 60)
        if filter.variant != .standard { q.publisher = nil }
        do {
            results = try await hf.search(q)
        } catch {
            searchError = "Couldn't reach Hugging Face. Check your connection."
            results = []
        }
    }

    var filteredResults: [ModelMetadata] {
        filter.apply(results, advisor: advisor, task: advisorTask)
    }

    // MARK: Advisor

    func runAdvisor() async {
        advisorBusy = true
        advisorError = nil
        defer { advisorBusy = false }
        if !advisorDescription.trimmingCharacters(in: .whitespaces).isEmpty {
            advisorTask = AdvisorTask.infer(from: advisorDescription)
        }
        let keyword: String
        switch advisorTask {
        case .coding: keyword = "coder"
        case .reasoning: keyword = "r1"
        case .vision: keyword = "vl"
        case .embeddings: keyword = "embed"
        default: keyword = "instruct"
        }
        var pool: [String: ModelMetadata] = [:]
        for text in [keyword, ""] {
            let found = (try? await hf.search(SearchQuery(text: text, variant: advisorVariant, limit: 60))) ?? []
            for m in found { pool[m.id] = m }
        }
        if pool.isEmpty { advisorError = "Couldn't load models from Hugging Face."; return }
        hardware = HardwareProbe.current()
        let adv = advisor
        let task = advisorTask
        let shortlist = pool.values
            .filter { $0.variant == advisorVariant && adv.assess($0, task: task).verdict != .wontFit }
            .sorted { adv.quality($0, task: task) > adv.quality($1, task: task) }
            .prefix(16)
        let enriched = await hf.enrich(Array(shortlist))
        recommendations = adv.recommend(from: enriched, task: task)
        comparison = enriched.map { adv.assess($0, task: task) }.sorted { $0.quality > $1.quality }
    }

    // MARK: Usage & stats

    func refreshUsage() {
        usageSummary = usage.summary(usageRange)
        requestsToday = usage.summary(.today).requests
    }

    private func tick() {
        if let s = lastSpeed, Date().timeIntervalSince(s.at) < 8 { tokensPerSecond = s.value } else { tokensPerSecond = 0 }
        speedHistory.append(tokensPerSecond)
        if speedHistory.count > 40 { speedHistory.removeFirst() }
        hardware.availableBytes = HardwareProbe.availableMemory()
        swapBytes = HardwareProbe.swapUsedBytes()
        Task {
            if let pid = await supervisor.processID { serverMemoryBytes = Self.residentBytes(pid: pid) } else { serverMemoryBytes = 0 }
            uptime = await supervisor.uptime ?? 0
            await supervisor.checkAlive()
        }
        pressureHistory.append(Double(memoryPressure.rawValue))
        if pressureHistory.count > 360 { pressureHistory.removeFirst() }
        idleCheck()
    }

    static func residentBytes(pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        return size > 0 ? info.pti_resident_size : 0
    }

    private func idleCheck() {
        guard isRunning, app.onDemandLoading, app.idleUnloadMinutes > 0, let proxy, proxy.activeConnections == 0 else { return }
        let idle = Date().timeIntervalSince(proxy.lastActivity)
        if idle > Double(app.idleUnloadMinutes) * 60 {
            logs.append("Unloading after \(app.idleUnloadMinutes) min idle.")
            note("Unloaded after \(app.idleUnloadMinutes) min idle, freed \(formatBytes(serverMemoryBytes))")
            Task { await stopServer() }
        }
    }

    func note(_ text: String) {
        memoryEvents.insert((Date(), text), at: 0)
        if memoryEvents.count > 20 { memoryEvents.removeLast() }
    }

    // MARK: Memory pressure & power events

    private func startMemoryMonitor() {
        let monitor = MemoryMonitor()
        monitor.onChange = { [weak self] system in
            Task { @MainActor in self?.pressureChanged(system) }
        }
        memoryMonitor = monitor
    }

    private func pressureChanged(_ system: MemoryPressure) {
        swapBytes = HardwareProbe.swapUsedBytes()
        let level = MemoryPolicy.level(system: system, swapBytes: swapBytes)
        memoryPressure = level
        pressureCapActive = false
        for action in MemoryPolicy.actions(level: level, swapBytes: swapBytes, settings: app) {
            switch action {
            case .capContext(let tokens):
                pressureCapActive = true
                note("Context capped at \(formatContext(tokens)) while memory is tight")
            case .trimPromptCache(let percent):
                trimCacheWhenIdle(percent: percent)
            case .unloadModel:
                note("Unloaded the model: memory critical")
                Task { await stopServer() }
            }
        }
        proxy?.contextLimit = effectiveContextLimit
    }

    /// mlx_lm.server can't shrink its cache live, so apply a smaller budget with a restart once idle.
    private func trimCacheWhenIdle(percent: Int) {
        guard isRunning, var s = applied, s.promptCacheEnabled else { return }
        let target = max(s.promptCacheGB * Double(percent) / 100, 1)
        guard target < s.promptCacheGB else { return }
        Task { [weak self] in
            for _ in 0..<60 {
                guard let self else { return }
                if (self.proxy?.activeConnections ?? 0) == 0 { break }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            guard let self, self.isRunning else { return }
            s.promptCacheGB = target
            self.note("Prompt cache reduced to \(Int(target)) GB (restart)")
            self.draft.promptCacheGB = target
            await self.startServer(model: s.modelID)
        }
    }

    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.app.unloadOnSleep, self.isRunning else { return }
                self.note("Unloaded: Mac went to sleep")
                await self.stopServer()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.app.unloadOnScreenLock, self.isRunning else { return }
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                if self.isRunning, (self.proxy?.activeConnections ?? 0) == 0 {
                    self.note("Unloaded: screen locked")
                    await self.stopServer()
                }
            }
        }
    }

    // MARK: Agent control API

    private func startControlServer() {
        guard app.mcpEnabled else { return }
        do {
            let server = try ControlServer { [weak self] method, path, body in
                guard let self else { return (503, ["error": "App is closing"]) }
                return await self.handleControl(method: method, path: path, body: body)
            }
            try server.start(writingTo: paths.controlFile)
            control = server
        } catch {
            logs.append("Agent access unavailable: \(error.localizedDescription)")
        }
    }

    func setMCP(enabled: Bool) {
        app.mcpEnabled = enabled
        control?.stop()
        control = nil
        try? FileManager.default.removeItem(at: paths.controlFile)
        if enabled { startControlServer() }
    }

    private func statusJSON() -> [String: Any] {
        [
            "state": String(describing: serverState),
            "model": activeModelID ?? app.lastModelID ?? "",
            "endpoint": endpoint,
            "tokens_per_second": tokensPerSecond,
            "server_memory_gb": Double(serverMemoryBytes) / 1_073_741_824,
            "memory_pressure": memoryPressure.label,
            "installed_models": installed.map(\.id),
            "downloads": downloads.mapValues { ["fraction": $0.fraction, "failed": $0.failed as Any] },
        ]
    }

    private func approve(_ message: String, alwaysAsk: Bool = false) -> Bool {
        switch app.agentPermission {
        case .readOnly: return false
        case .fullControl: if !alwaysAsk { return true }
        case .askFirst: break
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "An agent wants to change MLX Player"
        alert.informativeText = message
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleControl(method: String, path: String, body: [String: Any]) async -> (Int, [String: Any]) {
        if path == "/status" { return (200, statusJSON()) }
        if app.agentPermission == .readOnly { return (403, ["error": "Agent access is read-only. Change it in MLX Player → Settings → Agents."]) }
        let model = body["model_id"] as? String ?? body["model"] as? String ?? ""
        switch path {
        case "/download":
            guard !model.isEmpty else { return (400, ["error": "model_id is required"]) }
            let size = await hf.repoSize(model) ?? 0
            let big = Double(size) / 1_073_741_824 >= app.largeDownloadGB
            guard approve("Download \(model) (\(formatBytes(size)))?", alwaysAsk: big) else { return (403, ["error": "The user denied the download."]) }
            download(ModelMetadata(id: model, diskBytes: size))
            return (200, ["started": model, "size_gb": Double(size) / 1_073_741_824])
        case "/start":
            guard !model.isEmpty else { return (400, ["error": "model_id is required"]) }
            guard approve("Load \(model) and start the server?") else { return (403, ["error": "The user denied starting the server."]) }
            var s = store.settings(for: model)
            if let c = body["context_length"] as? Int { s.contextLength = c }
            if let thinking = body["thinking"] as? Bool { s.chatTemplateArgs = thinking ? nil : #"{"enable_thinking":false}"# }
            store.save(s)
            if draft.modelID == model { draft = s }
            await startServer(model: model)
            return isRunning ? (200, statusJSON()) : (500, ["error": lastError ?? "The server did not start."])
        case "/settings":
            guard approve("Change saved settings for \(model)?") else { return (403, ["error": "The user denied the change."]) }
            var s = store.settings(for: model)
            let patch = body["settings"] as? [String: Any] ?? [:]
            if let v = patch["context_length"] as? Int { s.contextLength = v }
            if let v = patch["temperature"] as? Double { s.temperature = v }
            if let v = patch["top_p"] as? Double { s.topP = v }
            if let v = patch["top_k"] as? Int { s.topK = v }
            if let v = patch["max_tokens"] as? Int { s.maxTokens = v }
            if let v = patch["draft_model"] as? String { s.draftModel = v.isEmpty ? nil : v }
            store.save(s)
            if draft.modelID == model { draft = s }
            return (200, ["saved": model, "note": "Restart the server to apply."])
        case "/stop":
            guard approve("Stop the server and unload the model?") else { return (403, ["error": "The user denied stopping."]) }
            await stopServer()
            return (200, statusJSON())
        case "/delete":
            guard approve("Delete \(model) from disk?", alwaysAsk: true) else { return (403, ["error": "The user denied deletion."]) }
            delete(model: model)
            return (200, ["deleted": model])
        default:
            return (404, ["error": "Unknown endpoint"])
        }
    }

    // MARK: Clipboard helpers

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var curlSnippet: String {
        let id = draft.modelID.isEmpty ? "MODEL" : draft.modelID
        return """
        curl \(endpoint)/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{"model": "\(id)", "messages": [{"role": "user", "content": "Hello"}]}'
        """
    }

    var pythonSnippet: String {
        """
        from openai import OpenAI
        client = OpenAI(base_url="\(endpoint)", api_key="local")
        r = client.chat.completions.create(model="\(draft.modelID)", messages=[{"role": "user", "content": "Hello"}])
        print(r.choices[0].message.content)
        """
    }

    var envSnippet: String {
        "export OPENAI_BASE_URL=\(endpoint)\nexport OPENAI_API_KEY=local"
    }

    func claudeMCPCommand() -> String {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mlxplayer-mcp").path
        return "claude mcp add mlxplayer -- \"\(exe)\""
    }
}


final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
