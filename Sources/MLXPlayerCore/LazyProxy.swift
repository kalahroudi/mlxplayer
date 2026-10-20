import Foundation

private final class ResultBox<T>: @unchecked Sendable { var value: T? }

func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        sem.signal()
    }
    sem.wait()
    return box.value!
}

/// Sits on the public port. Starts the model when the first real request arrives, enforces the context
/// limit, and records usage. Streams responses straight through.
public final class LazyProxy: @unchecked Sendable {
    private let listener: TCPListener
    private let lock = NSLock()
    private var _backendPort = 0
    private var _contextLimit = 0
    private var _servedModel = ""
    private var _active = 0
    private var _lastActivity = Date()

    /// Called before forwarding a model request. Return true once the backend answers.
    public var ensureBackend: (@Sendable (_ requestedModel: String?) async -> Bool)?
    public var isBackendRunning: (@Sendable () -> Bool)?
    public var onRecord: (@Sendable (UsageRecord) -> Void)?
    /// Live generation speed while a streamed reply is in flight: tokens so far and seconds since the first token.
    public var onProgress: (@Sendable (_ tokens: Int, _ seconds: Double) -> Void)?
    public var onActiveChanged: (@Sendable (_ active: Int) -> Void)?

    public init(host: String = "127.0.0.1", port: Int) {
        self.host = host
        listener = TCPListener(host: host, port: port)
    }

    public let host: String
    /// Restricts who may connect, by IPv4 address in host byte order. Set before `start()`.
    public var peerFilter: (@Sendable (UInt32) -> Bool)? { get { listener.peerFilter } set { listener.peerFilter = newValue } }
    public var port: Int { listener.port }
    public var backendPort: Int { get { lock.withLock { _backendPort } } set { lock.withLock { _backendPort = newValue } } }
    /// 0 disables the limit.
    public var contextLimit: Int { get { lock.withLock { _contextLimit } } set { lock.withLock { _contextLimit = newValue } } }
    public var servedModel: String { get { lock.withLock { _servedModel } } set { lock.withLock { _servedModel = newValue } } }
    public var activeConnections: Int { lock.withLock { _active } }
    public var lastActivity: Date { lock.withLock { _lastActivity } }

    public func start() throws {
        try listener.start { [weak self] fd in self?.handle(fd) }
    }

    public func stop() { listener.stop() }

    private func bump(_ delta: Int) {
        let n: Int = lock.withLock {
            _active += delta
            _lastActivity = Date()
            return _active
        }
        onActiveChanged?(n)
    }

    private func respond(_ fd: Int32, _ status: Int, _ reason: String, _ body: Data, extra: [String: String] = [:]) {
        var headers = ["Access-Control-Allow-Origin": "*"]
        for (k, v) in extra { headers[k] = v }
        TCP.writeAll(fd, HTTPReader.response(status: status, reason: reason, body: body, extraHeaders: headers))
    }

    private func handle(_ client: Int32) {
        defer { TCP.close(client) }
        guard let req = HTTPReader.readRequest(fd: client) else { return }
        bump(1)
        defer { bump(-1) }

        let head = req.head
        let path = head.path.split(separator: "?").first.map(String.init) ?? head.path
        let started = Date()

        // Preflight and cheap probes never need the model loaded.
        if head.method == "OPTIONS" {
            respond(client, 204, "No Content", Data(), extra: [
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": head.header("Access-Control-Request-Headers") ?? "*",
            ])
            return
        }
        if path == "/health" {
            let body = try? JSONSerialization.data(withJSONObject: ["status": "ok", "model_loaded": isBackendRunning?() ?? false])
            respond(client, 200, "OK", body ?? Data())
            return
        }
        if path == "/v1/models", head.method == "GET", !(isBackendRunning?() ?? false) {
            let id = servedModel
            let model: [String: Any] = ["id": id, "object": "model", "created": 0, "owned_by": "mlx-player"]
            let body = try? JSONSerialization.data(withJSONObject: ["object": "list", "data": id.isEmpty ? [] : [model]])
            respond(client, 200, "OK", body ?? Data())
            return
        }

        let isModelCall = head.method == "POST"
        let requestedModel = isModelCall ? APIMeter.requestedModel(body: req.body) : nil
        let promptEstimate = isModelCall ? APIMeter.estimatePromptTokens(body: req.body) : 0
        let limit = contextLimit
        let userAgent = head.header("User-Agent")
        let clientName = APIMeter.clientName(userAgent: userAgent)

        if isModelCall, limit > 0, promptEstimate > limit {
            let msg = "This request is about \(promptEstimate) tokens, over the \(limit)-token context limit set in MLX Player."
            respond(client, 400, "Bad Request", APIMeter.openAIError(message: msg, code: "context_length_exceeded"))
            return
        }

        // Make sure the model is loaded; this may take a while on a cold start.
        if let ensure = ensureBackend {
            let ready = runBlocking { await ensure(requestedModel) }
            if !ready {
                respond(client, 503, "Service Unavailable",
                        APIMeter.openAIError(message: "The model could not be started. Check the log in MLX Player.", code: "model_unavailable"))
                return
            }
        }
        guard let backend = TCP.connect(host: "127.0.0.1", port: backendPort) else {
            respond(client, 502, "Bad Gateway",
                    APIMeter.openAIError(message: "Could not reach the model server.", code: "backend_unreachable"))
            return
        }
        defer { TCP.close(backend) }

        // Ask for usage in streams so tokens can be metered.
        var body = req.body
        let streaming = isModelCall && APIMeter.isStreaming(body: body)
        // Clients send names like "default" or a model that is not loaded; mlx-lm would try to fetch that name from
        // Hugging Face and fail, so always ask for what is actually loaded.
        let served = servedModel
        if isModelCall, var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            var changed = false
            if !served.isEmpty, let m = obj["model"] as? String, m != served { obj["model"] = served; changed = true }
            if streaming, obj["stream_options"] == nil { obj["stream_options"] = ["include_usage": true]; changed = true }
            if changed, let patched = try? JSONSerialization.data(withJSONObject: obj) { body = patched }
        }
        guard TCP.writeAll(backend, head.serialized(body: body)) else {
            respond(client, 502, "Bad Gateway", APIMeter.openAIError(message: "Lost the model server.", code: "backend_unreachable"))
            return
        }

        // Pipe the response through, remembering the tail for metering.
        var tail = Data()
        var firstByte: Date?
        var status = 200
        var sawHead = false
        var sseChunks = 0
        var firstDataAt: Date?
        var lastProgress = Date.distantPast
        while let chunk = TCP.read(backend) {
            if firstByte == nil { firstByte = Date() }
            if !sawHead {
                sawHead = true
                if let line = String(data: chunk.prefix(32), encoding: .utf8)?.split(separator: " "), line.count > 1,
                   let code = Int(line[1]) { status = code }
            }
            if streaming {
                let n = Self.countOccurrences(of: "data:", in: chunk)
                if n > 0 {
                    sseChunks += n
                    let now = Date()
                    if firstDataAt == nil { firstDataAt = now }
                    if let t0 = firstDataAt, now.timeIntervalSince(t0) > 0.4, now.timeIntervalSince(lastProgress) > 0.5 {
                        lastProgress = now
                        onProgress?(max(sseChunks - 1, 0), now.timeIntervalSince(t0))
                    }
                }
            }
            tail.append(chunk)
            if tail.count > 8192 { tail = Data(tail.suffix(8192)) }
            if !TCP.writeAll(client, chunk) { break }
        }

        guard isModelCall, path.hasPrefix("/v1/") else { return }
        let usage = APIMeter.usage(inResponseTail: tail)
        let tokensOut = usage?.completion ?? max(sseChunks - 2, 0)
        let tokensIn = usage?.prompt ?? promptEstimate
        let model = requestedModel ?? servedModel
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let ttft = firstByte.map { Int($0.timeIntervalSince(started) * 1000) }
        onRecord?(UsageRecord(model: model, client: clientName, tokensIn: tokensIn, tokensOut: tokensOut,
                              durationMs: ms, firstTokenMs: ttft, status: status))
    }

    static func countOccurrences(of needle: String, in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }
}
