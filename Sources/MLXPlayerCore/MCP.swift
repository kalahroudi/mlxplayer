import Foundation

public struct MCPTool {
    public var name: String
    public var description: String
    public var schema: [String: Any]
    public var run: ([String: Any]) async throws -> String

    public init(name: String, description: String, schema: [String: Any], run: @escaping ([String: Any]) async throws -> String) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }
}

/// Model Context Protocol server over newline-delimited JSON-RPC (stdio transport).
public final class MCPServer {
    private let tools: [MCPTool]
    private let name: String
    private let version: String

    public init(name: String = "mlxplayer", version: String = "1.0.0", tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.tools = tools
    }

    /// Handles one JSON-RPC message. Returns the response to write, or nil for notifications.
    public func handle(_ line: String) async -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = obj["id"]
        let method = obj["method"] as? String ?? ""
        let params = obj["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }  // notification

        func ok(_ result: [String: Any]) -> Data? { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
        func err(_ code: Int, _ message: String) -> Data? {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }

        switch method {
        case "initialize":
            return ok([
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            let list = tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] as [String: Any] }
            return ok(["tools": list])
        case "tools/call":
            guard let toolName = params["name"] as? String, let tool = tools.first(where: { $0.name == toolName }) else {
                return err(-32602, "Unknown tool")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await tool.run(args)
                return ok(["content": [["type": "text", "text": text]]])
            } catch {
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return err(-32601, "Method not found")
        }
    }

    private func encode(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Reads stdin until EOF, answering each line.
    public func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let response = await handle(trimmed) {
                FileHandle.standardOutput.write(response + Data("\n".utf8))
            }
        }
    }
}

/// The tools agents get: read-only analysis runs locally, changes go through the running app for approval.
public enum MCPTools {
    static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    static func json(_ obj: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func describe(_ a: Assessment) -> [String: Any] {
        [
            "model_id": a.model.id,
            "fit": a.verdict.rawValue,
            "weights_gb": round(Double(a.weightsBytes) / 1_073_741_824 * 10) / 10,
            "recommended_context": a.recommendedContext,
            "safe_max_context": a.safeMaxContext,
            "kv_cache_gb_at_recommended": round(Double(a.kvBytesAtRecommended) / 1_073_741_824 * 10) / 10,
            "headroom_gb": round(Double(a.headroomBytes) / 1_073_741_824 * 10) / 10,
            "estimated_tokens_per_second": Int(a.tokensPerSecond.rounded()),
            "quality_score": Int(a.quality.rounded()),
            "bits": a.model.bits,
            "variant": a.model.variant.rawValue,
            "exact_kv_estimate": a.model.hasExactKV,
        ]
    }

    public static func make(paths: AppPaths, hf: HuggingFaceClient = HuggingFaceClient(),
                            control: ControlClient? = nil) -> [MCPTool] {
        let control = control ?? ControlClient(paths: paths)
        let taskEnum = AdvisorTask.allCases.map(\.rawValue)

        func parseTask(_ args: [String: Any]) -> AdvisorTask {
            if let t = args["task"] as? String, let task = AdvisorTask(rawValue: t) { return task }
            if let d = args["description"] as? String { return AdvisorTask.infer(from: d) }
            return .chat
        }

        return [
            MCPTool(name: "get_hardware",
                    description: "Report this Mac's chip, memory, GPU memory limit and bandwidth, and how much memory a model may use.",
                    schema: schema([:])) { _ in
                let hw = HardwareProbe.current()
                let adv = Advisor(hardware: hw)
                return json([
                    "chip": hw.chip, "memory_gb": Double(hw.memoryBytes) / 1_073_741_824,
                    "gpu_cores": hw.gpuCores, "cpu_cores": hw.cpuCores,
                    "memory_bandwidth_gbs": hw.bandwidthGBs,
                    "gpu_limit_gb": Double(hw.gpuLimitBytes) / 1_073_741_824,
                    "available_gb": Double(hw.availableBytes) / 1_073_741_824,
                    "model_budget_gb": Double(adv.budgetBytes) / 1_073_741_824,
                ])
            },
            MCPTool(name: "search_models",
                    description: "Search MLX models on Hugging Face (mlx-community by default).",
                    schema: schema([
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Max results, default 15"],
                        "variant": ["type": "string", "enum": ModelVariant.allCases.map(\.rawValue)],
                    ])) { args in
                let variant = (args["variant"] as? String).flatMap(ModelVariant.init(rawValue:)) ?? .standard
                let limit = args["limit"] as? Int ?? 15
                let results = try await hf.search(SearchQuery(text: args["query"] as? String ?? "", variant: variant, limit: limit))
                return json(results.map { ["model_id": $0.id, "bits": $0.bits, "params_b": $0.totalParamsB as Any,
                                           "downloads": $0.downloads, "size_gb": Double($0.diskBytes) / 1_073_741_824] })
            },
            MCPTool(name: "analyze_model",
                    description: "Check whether a model fits this Mac and get a context size, speed estimate and memory breakdown.",
                    schema: schema([
                        "model_id": ["type": "string"],
                        "task": ["type": "string", "enum": taskEnum],
                    ], required: ["model_id"])) { args in
                guard let id = args["model_id"] as? String else { throw ControlClientError.failed("model_id is required") }
                var meta = ModelMetadata.fromName(id)
                if let cfg = await hf.config(for: id) { meta = meta.applying(config: cfg) }
                if let size = await hf.repoSize(id) { meta.diskBytes = size }
                let adv = Advisor(hardware: HardwareProbe.current())
                return json(describe(adv.assess(meta, task: parseTask(args))))
            },
            MCPTool(name: "recommend_models",
                    description: "Recommend the best MLX models for a job on this Mac: best overall, highest quality and fastest, each with a context size.",
                    schema: schema([
                        "task": ["type": "string", "enum": taskEnum],
                        "description": ["type": "string", "description": "Free-text description of the job"],
                        "variant": ["type": "string", "enum": ModelVariant.allCases.map(\.rawValue)],
                    ])) { args in
                let task = parseTask(args)
                let variant = (args["variant"] as? String).flatMap(ModelVariant.init(rawValue:)) ?? .standard
                let keyword: String
                switch task {
                case .coding: keyword = "coder"
                case .reasoning: keyword = "r1"
                case .vision: keyword = "vl"
                case .embeddings: keyword = "embed"
                default: keyword = "instruct"
                }
                var pool: [String: ModelMetadata] = [:]
                for q in [keyword, ""] {
                    for m in (try? await hf.search(SearchQuery(text: q, variant: variant, limit: 60))) ?? [] { pool[m.id] = m }
                }
                let adv = Advisor(hardware: HardwareProbe.current())
                // Rank cheaply by name, then fetch real configs for the top candidates only.
                let shortlist = pool.values
                    .filter { $0.variant == variant && adv.assess($0, task: task).verdict != .wontFit }
                    .sorted { adv.quality($0, task: task) > adv.quality($1, task: task) }
                    .prefix(16)
                let enriched = await hf.enrich(Array(shortlist))
                let rec = adv.recommend(from: enriched, task: task)
                return json([
                    "task": task.rawValue,
                    "best_overall": rec.bestOverall.map(describe) as Any,
                    "highest_quality": rec.highestQuality.map(describe) as Any,
                    "fastest": rec.fastest.map(describe) as Any,
                ])
            },
            MCPTool(name: "get_status", description: "Current server state, loaded model, endpoint, memory use and speed.",
                    schema: schema([:])) { _ in json(try await control.call("GET", "/status")) },
            MCPTool(name: "download_model", description: "Download a model into the Hugging Face cache. Asks the user to approve.",
                    schema: schema(["model_id": ["type": "string"]], required: ["model_id"])) { args in
                json(try await control.call("POST", "/download", body: args))
            },
            MCPTool(name: "start_server",
                    description: "Load a model and start the OpenAI-compatible server. Optional context_length and thinking (false disables thinking mode). Asks the user to approve.",
                    schema: schema([
                        "model_id": ["type": "string"],
                        "context_length": ["type": "integer"],
                        "thinking": ["type": "boolean"],
                    ], required: ["model_id"])) { args in
                json(try await control.call("POST", "/start", body: args))
            },
            MCPTool(name: "update_settings",
                    description: "Change saved server settings for a model (context_length, temperature, top_p, top_k, max_tokens, draft_model). Asks the user to approve.",
                    schema: schema(["model_id": ["type": "string"], "settings": ["type": "object"]], required: ["model_id", "settings"])) { args in
                json(try await control.call("POST", "/settings", body: args))
            },
            MCPTool(name: "stop_server", description: "Stop the server and free its memory. Asks the user to approve.",
                    schema: schema([:])) { _ in json(try await control.call("POST", "/stop")) },
            MCPTool(name: "delete_model", description: "Delete a downloaded model from disk. Always asks the user.",
                    schema: schema(["model_id": ["type": "string"]], required: ["model_id"])) { args in
                json(try await control.call("POST", "/delete", body: args))
            },
        ]
    }
}
