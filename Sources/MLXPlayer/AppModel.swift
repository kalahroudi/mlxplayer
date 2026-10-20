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
    /// Quick-chat conversation. Owned here so it survives leaving the Chat screen and is saved to chat.json.
    @ObservationIgnored let chat = ChatModel(file: AppPaths().chatFile)
    let hf = HuggingFaceClient()
    let installer: Installer
    let updater: Updater
    private(set) var supervisor: ServerSupervisor!
    private var proxy: LazyProxy?
    private var control: ControlServer?
    private var memoryMonitor: MemoryMonitor?
    private var downloadsByID: [String: ModelDownload] = [:]
    private var loadTask: Task<Bool, Never>?
    private var timer: Timer?
    private var lastSpeed: (value: Double, at: Date)?
    /// Recent failed starts, to stop a request from restarting a broken model in a loop.
    private var failures: [Date] = []
    /// Readable from the proxy's threads without hopping to the main actor.
    private let runningFlag = AtomicFlag()
    /// Supervisor state changes, delivered to the main actor strictly in order.
    private let stateStream: AsyncStream<ServerState>
    private let stateSink: AsyncStream<ServerState>.Continuation

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
    /// Background results shown as toasts. Newest last; each removes itself after a few seconds.
    private(set) var toasts: [Toast] = []
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
    /// Latest whole-machine reading and short histories (0...1) for the Overview charts, one point per tick.
    var system = SystemSnapshot()
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var vramHistory: [Double] = []
    @ObservationIgnored private let sampler = SystemSampler()
    static let historyLength = 90
    var memoryEvents: [(time: Date, text: String)] = []
    private var pressureCapActive = false
    private var systemPressure: MemoryPressure = .normal

    // MARK: Library & downloads
    var installed: [InstalledModel] = []
    /// Half-finished downloads found on disk (not currently transferring).
    var partials: [PartialModel] = []
    var downloads: [String: DownloadProgress] = [:]

    // MARK: Discover
    var searchText = ""
    var searchSort: SearchSort = .downloads
    var filter = ModelFilter()
    var publisher: String? = "mlx-community"
    var results: [ModelMetadata] = []
    var searching = false
    var loadingMore = false
    private(set) var searchCursor: URL?
    var hasMoreResults: Bool { searchCursor != nil }
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
        self.updater = Updater(paths: paths)
        self.app = store.app
        self.draft = ServerSettings(modelID: store.app.lastModelID ?? "")
        self.isInstalled = installer.isInstalled || (store.app.customServerPath != nil)
        let (stream, sink) = AsyncStream<ServerState>.makeStream()
        self.stateStream = stream
        self.stateSink = sink
        self.supervisor = ServerSupervisor(paths: paths, logs: logs) { state in sink.yield(state) }
        updater.onResult = { [weak self] ok, text in
            self?.notify(ok ? .success : .error, ok ? "Update installed" : "Update didn't apply", detail: text, action: "Details", screen: .settings)
        }
        updater.beforeQuit = { [weak self] in await self?.supervisor.stop() }
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
        if let pid = PIDRecord.reapOrphan(at: paths.serverPidFile) {
            logs.append("Stopped a model server left over from the last run (pid \(pid)).")
            note("Cleaned up a leftover model server")
        }
        let sup = supervisor!
        Task { @MainActor [weak self] in
            guard let stream = self?.stateStream else { return }
            for await state in stream { self?.handle(state: state) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            sup.killNow()
        }
        refreshInstalled()
        updater.confirmLaunch()
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

    func notify(_ kind: Toast.Kind, _ title: String, detail: String? = nil, action: String? = nil, screen: Screen? = nil) {
        let toast = Toast(kind: kind, title: title, detail: detail, actionTitle: action, screen: screen)
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        let seconds: UInt64 = kind == .error ? 12 : 6
        Task { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); dismiss(toast.id) }
    }

    func dismiss(_ id: UUID) { toasts.removeAll { $0.id == id } }

    private func handle(state: ServerState) {
        let previous = serverState
        serverState = state
        if state == .running, previous != .running {
            notify(.success, "Model loaded", detail: activeModelID.map { ModelMetadata.fromName($0).displayName }, action: "Open server", screen: .server)
        }
        runningFlag.value = (state == .running)
        if case .failed(let message) = state {
            lastError = message
            notify(.error, "Model failed to start", detail: message, action: "Show logs", screen: .logs)
        }
        if state == .stopped || state == .stopping { uptime = 0 }
    }

    /// Safety net: if a state change was missed, the supervisor is the source of truth.
    private func reconcileServerState() async {
        let actual = await supervisor.state
        if actual != serverState { handle(state: actual) }
        if actual == .running, let id = await supervisor.activeSettings?.modelID, activeModelID != id {
            activeModelID = id
        }
    }

    // MARK: Derived

    var isRunning: Bool { serverState == .running }
    var publicPort: Int { draft.port }
    var endpoint: String { "http://\(draft.host == "0.0.0.0" ? "127.0.0.1" : draft.host):\(draft.port)/v1" }
    var advisor: Advisor {
        var a = Advisor(hardware: hardware, reserveBytes: UInt64(app.reserveGB * 1_073_741_824))
        let here = app.benchmarks.values.filter { $0.chip == hardware.chip }
        a.measuredSpeeds = Dictionary(uniqueKeysWithValues: here.map { ($0.modelID, $0.decodeTokensPerSecond) })
        a.speedCalibration = SpeedCalibration.factor(results: here, chip: hardware.chip, estimate: { a.rawTokensPerSecond($0) })
        return a
    }

    var effectiveContextLimit: Int {
        var limit = applied?.contextLength ?? draft.contextLength
        if pressureCapActive { limit = min(limit, app.cappedContext) }
        return limit
    }

    var activeMeta: ModelMetadata? {
        guard let id = shownModelID else { return nil }
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
        p.onProgress = { [weak self] tokens, secs in
            Task { @MainActor in self?.lastSpeed = (Double(tokens) / secs, Date()) }
        }
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
        if r.client == "Benchmark" { return }
        usage.record(r)
        let gen = Double(r.durationMs - (r.firstTokenMs ?? 0)) / 1000
        if r.tokensOut > 0, gen > 0.05 { lastSpeed = (Double(r.tokensOut) / gen, Date()) }
        refreshUsage()
    }

    /// Starts `model` (or the saved one) on the internal port behind the proxy.
    /// A newer start or a stop cancels this one; that is not an error.
    /// What the user just asked for, set the instant they act so the UI can respond before the server reports anything.
    enum Transition: Equatable { case loading(String), unloading }
    var transition: Transition?

    var isBusy: Bool { transition != nil || serverState.isStarting || serverState == .stopping }

    func startServer(model: String? = nil, ownRequests: Int = 0) async {
        let id = model ?? draft.modelID
        guard transition == nil else {
            notify(.info, "Still working", detail: "Another model change is in progress. Try again when it finishes.")
            return
        }
        transition = .loading(id)
        defer { transition = nil }
        await performStart(model: model, ownRequests: ownRequests)
    }

    private func performStart(model: String? = nil, ownRequests: Int = 0) async {
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

        // Free the old model first, so its memory counts as available for the new one.
        if serverState.isActive || serverState == .stopping {
            await waitForIdle(keeping: ownRequests)
            let freed = await supervisor.footprintBytes
            await supervisor.stop()
            if freed > 0 { logs.append("Unloaded previous model, freed \(formatBytes(freed)).") }
        }
        hardware.availableBytes = HardwareProbe.availableMemory()
        if app.autoReduceContext { settings = fitToAvailableMemory(settings, meta: meta) }

        if proxy == nil || proxy?.port != settings.port { draft.port = settings.port; startProxy() }
        guard let backendPort = TCP.firstFreePort(from: settings.port + 1) else {
            lastError = "No free port near \(settings.port). Pick another in Server → Network."
            return
        }
        proxy?.backendPort = backendPort
        proxy?.servedModel = id
        if supportedFlags == nil { supportedFlags = await supervisor.probeFlags(custom: app.customServerPath) }

        activeModelID = id
        app.lastModelID = id
        store.save(settings)

        var attempt = settings
        var retried = false
        while true {
            do {
                try await supervisor.start(settings: attempt, port: backendPort, supportedFlags: supportedFlags,
                                           customExecutable: app.customServerPath)
                await reconcileServerState()
                applied = attempt
                if draft.modelID == id, attempt != draft, !retried { draft = attempt }
                proxy?.contextLimit = effectiveContextLimit
                failures.removeAll()
                return
            } catch ServerError.cancelled {
                return
            } catch ServerError.outOfMemory where app.autoReduceContext && !retried && attempt.contextLength > 4096 {
                // One automatic retry with half the context and cache before giving up.
                retried = true
                attempt.contextLength = max(attempt.contextLength / 2, 4096)
                attempt.promptCacheGB = max(attempt.promptCacheGB / 2, 1)
                logs.append("Out of memory. Retrying with context \(formatContext(attempt.contextLength)) and a smaller cache.")
                note("Out of memory: retried with context \(formatContext(attempt.contextLength))")
            } catch {
                failures.append(Date())
                lastError = error.localizedDescription
                await reconcileServerState()
                return
            }
        }
    }

    /// Lowers the context until weights + KV cache fit in the memory that is free right now.
    private func fitToAvailableMemory(_ settings: ServerSettings, meta: ModelMetadata) -> ServerSettings {
        var s = settings
        let available = Double(hardware.availableBytes)
        guard available > 0 else { return s }
        let weights = Double(advisor.weightsBytes(meta))
        let perToken = meta.kvBytesPerToken(elementBytes: Double(s.kvBits ?? 16) / 8)
        func need(_ ctx: Int) -> Double { weights + perToken * Double(ctx) + (s.promptCacheEnabled ? 0.25 * 1_073_741_824 : 0) }
        guard need(s.contextLength) > available * 0.92 else { return s }
        let original = s.contextLength
        for step in Advisor.contextSteps.reversed() where step < original && need(step) <= available * 0.92 {
            s.contextLength = step
            logs.append("Only \(formatBytes(hardware.availableBytes)) free right now. Context \(formatContext(original)) → \(formatContext(step)) for this run.")
            note("Context lowered to \(formatContext(step)): low free memory")
            return s
        }
        logs.append("Low free memory (\(formatBytes(hardware.availableBytes))). The Mac may swap while this model loads.")
        return s
    }

    func stopServer() async {
        if transition == nil { transition = .unloading }
        defer { if transition == .unloading { transition = nil } }
        await supervisor.stop()
        await reconcileServerState()
        applied = nil
    }

    /// Unloads the model. With `waitForIdle`, lets running requests finish first (up to that many seconds).
    func unload(reason: String, waitForIdle: TimeInterval = 0, onlyIfIdle: Bool = false) async {
        var waited: TimeInterval = 0
        while (proxy?.activeConnections ?? 0) > 0 {
            if onlyIfIdle { return }
            if waited >= waitForIdle { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard isRunning else { return }
        let freed = await supervisor.footprintBytes
        // A request may have arrived while we measured; idle unloads must never cut one off.
        if onlyIfIdle, (proxy?.activeConnections ?? 0) > 0 { return }
        await stopServer()
        note("\(reason)" + (freed > 0 ? ", freed \(formatBytes(freed))" : ""))
        logs.append("Unloaded: \(reason)")
    }

    /// Switch the loaded model from anywhere in the app. Running requests finish first; if the new model
    /// fails to load, the previous one is brought back so the endpoint is not left empty.
    func switchModel(to id: String) async {
        if isRunning, activeModelID == id { return }
        let previous = isRunning ? activeModelID : nil
        await startServer(model: id)
        if !isRunning, !serverState.isStarting, let previous, previous != id, transition == nil, isInstalledModel(previous) {
            notify(.error, "Could not load \(ModelMetadata.fromName(id).displayName)",
                   detail: "Bringing back \(ModelMetadata.fromName(previous).displayName).", action: "Show logs", screen: .logs)
            await startServer(model: previous)
        }
    }

    /// Waits (up to `timeout` seconds) for requests in flight to finish, so a switch or restart does not cut a reply off.
    private func waitForIdle(keeping own: Int = 0, timeout: Double = 60) async {
        guard activeRequests > own else { return }
        logs.append("Waiting for \(activeRequests - own) running request(s) to finish before changing the model.")
        let end = Date().addingTimeInterval(timeout)
        while activeRequests > own, Date() < end { try? await Task.sleep(for: .milliseconds(250)) }
        if activeRequests > own { logs.append("Still \(activeRequests - own) request(s) running after \(Int(timeout)) s; changing the model anyway.") }
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
        failures.removeAll { Date().timeIntervalSince($0) > 300 }
        if failures.count >= 3 {
            lastError = "The model failed to start 3 times. Fix the problem, then load it again."
            return false
        }
        var target = activeModelID ?? app.lastModelID
        if app.switchModelsByRequest, let r = requested, isInstalledModel(r) { target = r }
        guard let target else { return false }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            await self.startServer(model: target, ownRequests: 1)
            return self.isRunning
        }
        loadTask = task
        let ok = await task.value
        loadTask = nil
        return ok
    }

    /// The model the UI should present: the loaded one, else the last used one while it is still installed.
    var shownModelID: String? {
        if isRunning || serverState.isStarting { return activeModelID ?? app.lastModelID }
        return [activeModelID, app.lastModelID].compactMap { $0 }.first { isInstalledModel($0) }
    }

    private func isInstalledModel(_ id: String?) -> Bool {
        guard let id else { return false }
        return installed.contains { $0.id == id }
    }

    // MARK: Library

    func refreshInstalled() {
        installed = ModelLibrary.scan(hub: paths.hfHub)
        partials = ModelLibrary.scanPartials(hub: paths.hfHub).filter { downloadsByID[$0.id] == nil }
        if !isRunning, !serverState.isStarting, let a = activeModelID, !isInstalledModel(a) { activeModelID = nil }
    }

    func delete(model id: String) {
        try? ModelLibrary.delete(hub: paths.hfHub, id: id)
        refreshInstalled()
        if app.lastModelID == id {
            app.lastModelID = installed.first?.id
            draft.modelID = app.lastModelID ?? ""
        }
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
            refreshInstalled()
            if p.finished {
                notify(.success, "Download complete", detail: ModelMetadata.fromName(p.modelID).displayName, action: "Open library", screen: .library)
            } else if let why = p.failed, why != "Paused" {
                notify(.error, "Download failed", detail: "\(ModelMetadata.fromName(p.modelID).displayName): \(why)", action: "Show logs", screen: .logs)
            }
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
        refreshInstalled()
    }

    func resumeDownload(_ meta: ModelMetadata) {
        downloads[meta.id] = nil
        download(meta)
    }

    func cancelDownload(_ id: String) {
        if let d = downloadsByID[id] { d.cancel() } else {
            try? ModelLibrary.delete(hub: paths.hfHub, id: id)
        }
        downloadsByID[id] = nil
        downloads[id] = nil
        refreshInstalled()
    }

    /// Continues a download left over from an earlier session; already fetched files are kept.
    func resumePartial(_ id: String) {
        download(installed.first { $0.id == id }?.meta ?? ModelMetadata.fromName(id))
    }

    func resumeAllPartials() {
        for p in partials where downloadsByID[p.id] == nil { resumePartial(p.id) }
    }

    func pauseAllDownloads() { for id in Array(downloadsByID.keys) { pauseDownload(id) } }

    // MARK: Search

    func search(refresh: Bool = false) async {
        searching = true
        searchError = nil
        defer { searching = false }
        var q = SearchQuery(text: searchText, publisher: publisher, sort: searchSort, variant: filter.variant, format: filter.format, limit: 30)
        if filter.variant != .standard || filter.format != .mlx { q.publisher = nil }
        do {
            let page = try await hf.searchPage(q, refresh: refresh)
            results = page.models
            searchCursor = page.next
        } catch {
            searchError = Self.searchMessage(error)
            results = []
            searchCursor = nil
        }
    }

    /// Fetches the next page and appends it. Pages are small, so the list never loads everything at once.
    func loadMoreResults() async {
        guard let cursor = searchCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await hf.searchPage(SearchQuery(), cursor: cursor)
            let known = Set(results.map(\.id))
            results += page.models.filter { !known.contains($0.id) }
            searchCursor = page.next
        } catch {
            searchError = Self.searchMessage(error)
        }
    }

    private static func searchMessage(_ error: Error) -> String {
        if error is URLError { return "Couldn't reach Hugging Face. Check your connection." }
        return error.localizedDescription
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
        // Keep the last measured speed for a while after a reply ends, so the tile does not flash back to a dash.
        if let s = lastSpeed, Date().timeIntervalSince(s.at) < 300 { tokensPerSecond = s.value } else { tokensPerSecond = 0 }
        speedHistory.append(tokensPerSecond)
        if speedHistory.count > 40 { speedHistory.removeFirst() }
        hardware.availableBytes = HardwareProbe.availableMemory()
        swapBytes = HardwareProbe.swapUsedBytes()
        recordSystemSample()
        Task {
            serverMemoryBytes = await supervisor.footprintBytes
            uptime = await supervisor.uptime ?? 0
            await supervisor.checkAlive()
            await reconcileServerState()
        }
        let system = MemoryMonitor.currentLevel()
        if system != systemPressure { pressureChanged(system) }
        pressureHistory.append(Double(memoryPressure.rawValue))
        if pressureHistory.count > 360 { pressureHistory.removeFirst() }
        idleCheck()
        updater.autoCheckIfDue(enabled: app.autoCheckUpdates)
    }

    func sampleSystem() { recordSystemSample() }

    private func recordSystemSample() {
        let snap = sampler.sample()
        system = snap
        func push(_ array: inout [Double], _ v: Double) {
            array.append(min(max(v, 0), 1))
            if array.count > Self.historyLength { array.removeFirst(array.count - Self.historyLength) }
        }
        push(&cpuHistory, snap.cpu)
        push(&gpuHistory, snap.gpu ?? 0)
        let total = Double(max(snap.memory.total, 1))
        push(&memoryHistory, Double(snap.memory.used) / total)
        let limit = Double(max(hardware.gpuLimitBytes, 1))
        push(&vramHistory, Double(snap.gpuMemoryBytes ?? 0) / limit)
    }

    private func idleCheck() {
        guard isRunning, app.onDemandLoading, app.idleUnloadMinutes > 0, let proxy, proxy.activeConnections == 0 else { return }
        let idle = Date().timeIntervalSince(proxy.lastActivity)
        if idle > Double(app.idleUnloadMinutes) * 60 {
            Task { await unload(reason: "Idle for \(app.idleUnloadMinutes) min", onlyIfIdle: true) }
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
        systemPressure = system
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
                Task { await unload(reason: "Memory critical", waitForIdle: 60) }
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
                await self.unload(reason: "Mac went to sleep")
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.app.unloadOnScreenLock, self.isRunning else { return }
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                if self.isRunning, (self.proxy?.activeConnections ?? 0) == 0 {
                    await self.unload(reason: "Screen locked")
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
            "error": lastError ?? "",
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

    // MARK: Benchmark

    var benchmarking: String?

    /// Loads the model if needed, streams one fixed prompt through the endpoint and stores the measured speed.
    func benchmark(model id: String? = nil) async {
        guard benchmarking == nil else { return }
        guard let target = id ?? activeModelID ?? app.lastModelID else { notify(.error, "Pick a model first"); return }
        benchmarking = target
        defer { benchmarking = nil }
        if !(isRunning && activeModelID == target) {
            await startServer(model: target)
            guard isRunning, activeModelID == target else { return }
        }
        do {
            let url = URL(string: endpoint)!
            let result = try await SpeedBenchmark.run(endpoint: url, model: target, chip: hardware.chip)
            app.benchmarks[target] = result
            notify(.success, "\(Int(result.decodeTokensPerSecond)) tokens/s",
                   detail: "\(ModelMetadata.fromName(target).displayName) · first token \(result.firstTokenMs) ms",
                   action: "Library", screen: .library)
        } catch {
            notify(.error, "Benchmark failed", detail: error.localizedDescription, action: "Show logs", screen: .logs)
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
        return "claude mcp add -s user mlxplayer -- \"\(exe)\""
    }

    enum MCPRegistration { case notInstalled, installed, outdated }

    /// Looks for an `mlxplayer` server in Claude Code's config (user scope or any project) and whether it points at this app.
    func mcpRegistration() -> MCPRegistration {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notInstalled }
        var servers: [[String: Any]] = []
        if let s = (root["mcpServers"] as? [String: Any])?["mlxplayer"] as? [String: Any] { servers.append(s) }
        for (_, project) in (root["projects"] as? [String: Any]) ?? [:] {
            if let s = ((project as? [String: Any])?["mcpServers"] as? [String: Any])?["mlxplayer"] as? [String: Any] { servers.append(s) }
        }
        if servers.isEmpty { return .notInstalled }
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mlxplayer-mcp").path
        return servers.contains { ($0["command"] as? String) == exe } ? .installed : .outdated
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
