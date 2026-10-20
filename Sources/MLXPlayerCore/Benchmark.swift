import Foundation

/// A measured speed for one model on this Mac.
public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var modelID: String
    /// Tokens per second while generating, after the first token.
    public var decodeTokensPerSecond: Double
    /// Wait before the first token, which includes reading the prompt.
    public var firstTokenMs: Int
    public var tokens: Int
    public var measuredAt: Date
    public var chip: String

    public init(modelID: String, decodeTokensPerSecond: Double, firstTokenMs: Int, tokens: Int,
                measuredAt: Date = Date(), chip: String) {
        self.modelID = modelID
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.firstTokenMs = firstTokenMs
        self.tokens = tokens
        self.measuredAt = measuredAt
        self.chip = chip
    }
}

public enum BenchmarkError: Error, LocalizedError, Equatable {
    case http(Int)
    case tooShort(Int)
    public var errorDescription: String? {
        switch self {
        case .http(let c): return "The server answered HTTP \(c)."
        case .tooShort(let n): return "The model produced only \(n) tokens, too few to measure."
        }
    }
}

/// Measures decode speed by streaming one fixed prompt through the OpenAI-compatible endpoint.
public enum SpeedBenchmark {
    public static let prompt = "Write a short story about a lighthouse keeper who finds a message in a bottle."
    public static let userAgent = "MLXPlayer-Benchmark"
    static let minimumTokens = 8

    public static func run(endpoint: URL, model: String, maxTokens: Int = 160, chip: String,
                           session: URLSession = .shared) async throws -> BenchmarkResult {
        var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": model, "stream": true, "max_tokens": maxTokens, "temperature": 0,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (bytes, resp) = try await session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw BenchmarkError.http(http.statusCode) }
        var times: [Date] = []
        for try await line in bytes.lines where hasContent(line) { times.append(Date()) }
        guard let summary = summarize(chunkTimes: times, start: start) else { throw BenchmarkError.tooShort(times.count) }
        return BenchmarkResult(modelID: model, decodeTokensPerSecond: summary.tokensPerSecond,
                               firstTokenMs: summary.firstTokenMs, tokens: times.count, chip: chip)
    }

    /// True for an SSE line that carries generated text (answer or reasoning).
    static func hasContent(_ line: String) -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else { return false }
        for key in ["content", "reasoning_content", "reasoning"] {
            if let s = delta[key] as? String, !s.isEmpty { return true }
        }
        return false
    }

    /// One chunk is about one token for mlx_lm. Speed is measured between the first and last chunk.
    static func summarize(chunkTimes: [Date], start: Date) -> (tokensPerSecond: Double, firstTokenMs: Int)? {
        guard chunkTimes.count >= minimumTokens, let first = chunkTimes.first, let last = chunkTimes.last else { return nil }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return nil }
        return (Double(chunkTimes.count - 1) / span, Int(first.timeIntervalSince(start) * 1000))
    }
}

/// Turns measured speeds into better estimates for models that were not measured.
public enum SpeedCalibration {
    /// Below this many active parameters decode speed is bound by per-token overhead, not memory
    /// bandwidth, so such a benchmark says nothing about larger models (a 0.5B model measured 379 t/s on an M4 Max).
    static let minimumActiveParamsB = 3.0

    /// Median of measured / estimated across benchmarks on this chip, kept in a sane range.
    public static func factor(results: [BenchmarkResult], chip: String, estimate: (ModelMetadata) -> Double) -> Double {
        let ratios = results.filter { $0.chip == chip }.compactMap { r -> Double? in
            let meta = ModelMetadata.fromName(r.modelID)
            guard (meta.activeParamsB ?? meta.totalParamsB ?? 0) >= minimumActiveParamsB else { return nil }
            let e = estimate(meta)
            return e > 0 && r.decodeTokensPerSecond > 0 ? r.decodeTokensPerSecond / e : nil
        }.sorted()
        guard !ratios.isEmpty else { return 1 }
        let median = ratios.count % 2 == 1 ? ratios[ratios.count / 2] : (ratios[ratios.count / 2 - 1] + ratios[ratios.count / 2]) / 2
        return min(max(median, 0.25), 2)
    }
}
