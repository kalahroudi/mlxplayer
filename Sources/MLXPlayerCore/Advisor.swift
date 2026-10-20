import Foundation

public enum AdvisorTask: String, Codable, CaseIterable, Sendable {
    case coding, chat, reasoning, longDocuments, toolCalling, vision, embeddings, fastest

    public var label: String {
        switch self {
        case .coding: return "Coding agent"
        case .chat: return "Chat assistant"
        case .reasoning: return "Reasoning & math"
        case .longDocuments: return "Long documents"
        case .toolCalling: return "Tool calling"
        case .vision: return "Vision"
        case .embeddings: return "Embeddings"
        case .fastest: return "Fastest"
        }
    }

    /// Context length worth planning for, before memory limits are applied.
    public var preferredContext: Int {
        switch self {
        case .coding, .toolCalling: return 65_536
        case .chat, .reasoning: return 32_768
        case .longDocuments: return 131_072
        case .vision: return 16_384
        case .embeddings, .fastest: return 8_192
        }
    }

    /// Picks the most likely task from a free-text description. Plain keyword matching, no AI involved.
    public static func infer(from text: String) -> AdvisorTask {
        let t = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["image", "vision", "screenshot", "photo", "ocr"]) { return .vision }
        if has(["embed", "rag", "vector", "semantic search"]) { return .embeddings }
        if has(["code", "coding", "refactor", "repo", "typescript", "python", "rust", "swift", "programming", "bug"]) { return .coding }
        if has(["math", "reason", "proof", "logic", "puzzle"]) { return .reasoning }
        if has(["summar", "document", "pdf", "contract", "long context", "book"]) { return .longDocuments }
        if has(["tool", "agent", "function call", "mcp"]) { return .toolCalling }
        if has(["fast", "latency", "autocomplete", "quick"]) { return .fastest }
        return .chat
    }
}

public enum FitVerdict: String, Codable, Sendable {
    case comfortable, tight, wontFit

    public var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .tight: return "Tight"
        case .wontFit: return "Won't fit"
        }
    }
}

public struct Assessment: Equatable, Identifiable, Sendable {
    public var id: String { model.id }
    public var model: ModelMetadata
    public var verdict: FitVerdict
    public var weightsBytes: UInt64
    public var recommendedContext: Int
    public var safeMaxContext: Int
    public var kvBytesAtRecommended: UInt64
    public var headroomBytes: Int64
    public var tokensPerSecond: Double
    public var quality: Double
}

public struct Recommendations: Equatable, Sendable {
    public var bestOverall: Assessment?
    public var highestQuality: Assessment?
    public var fastest: Assessment?
}

public struct Advisor: Sendable {
    public var hardware: HardwareProfile
    /// Memory kept free for macOS and other apps.
    public var reserveBytes: UInt64
    /// Multiplier from benchmarks on this Mac (1 when none). Applied to speed estimates.
    public var speedCalibration: Double = 1
    /// Measured decode speed per model id; wins over the estimate.
    public var measuredSpeeds: [String: Double] = [:]

    public static let contextSteps = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144]

    public init(hardware: HardwareProfile, reserveBytes: UInt64 = 8 * 1_073_741_824) {
        self.hardware = hardware
        self.reserveBytes = reserveBytes
    }

    /// Memory a model may use: the GPU wired limit, but never so much that macOS has less than the reserve.
    public var budgetBytes: UInt64 {
        let ceiling = hardware.memoryBytes > reserveBytes ? hardware.memoryBytes - reserveBytes : 0
        return min(hardware.gpuLimitBytes, ceiling)
    }

    public func weightsBytes(_ m: ModelMetadata) -> UInt64 {
        if m.diskBytes > 0 { return m.diskBytes }
        let b = m.totalParamsB ?? 8
        return UInt64(b * 1e9 * (Double(m.bits) + (m.bits < 16 ? 0.5 : 0)) / 8)
    }

    /// Single-stream decode speed is bound by how fast the active weights stream from memory.
    public func tokensPerSecond(_ m: ModelMetadata) -> Double {
        if let measured = measuredSpeeds[m.id] { return measured }
        return rawTokensPerSecond(m) * speedCalibration
    }

    /// The bandwidth-based estimate before calibration.
    public func rawTokensPerSecond(_ m: ModelMetadata) -> Double {
        let active = m.activeParamsB ?? m.totalParamsB ?? 8
        let bytesPerParam = (Double(m.bits) + (m.bits < 16 ? 0.5 : 0)) / 8
        let bytesPerToken = active * 1e9 * bytesPerParam
        guard bytesPerToken > 0 else { return 0 }
        let efficiency = m.isMoE ? 0.45 : 0.8
        return hardware.bandwidthGBs * 1e9 * efficiency / bytesPerToken
    }

    /// 0...100 blend of model size, quantization loss, and fit for the task. A ranking aid, not a benchmark.
    public func quality(_ m: ModelMetadata, task: AdvisorTask) -> Double {
        let total = m.totalParamsB ?? 8
        let effective = m.isMoE ? (total * (m.activeParamsB ?? total)).squareRoot() * 1.4 : total
        var score = 20 + 12 * log2(effective + 1)
        switch m.bits {
        case ..<4: score -= 6
        case 4: score -= 3
        case 5: score -= 2
        case 6: score -= 1
        case 7...8: score -= 0.5
        default: break
        }
        let caps = m.capabilities
        switch task {
        case .coding: if caps.contains(.code) { score += 6 }
        case .reasoning: if caps.contains(.reasoning) { score += 6 }
        case .vision: score += caps.contains(.vision) ? 8 : -50
        case .embeddings: score += caps.contains(.embeddings) ? 20 : -50
        default: break
        }
        return min(max(score, 0), 100)
    }

    public func assess(_ m: ModelMetadata, task: AdvisorTask) -> Assessment {
        let weights = weightsBytes(m)
        let budget = Double(budgetBytes)
        let perToken = m.kvBytesPerToken()
        let native = m.nativeContext ?? 32_768

        func used(_ ctx: Int) -> Double { Double(weights) + perToken * Double(ctx) }

        // Largest context step that stays within 70% of budget, up to the task's preference.
        let cap = min(task.preferredContext, native)
        var recommended = Self.contextSteps.first ?? 4_096
        for step in Self.contextSteps where step <= cap && used(step) <= budget * 0.7 { recommended = step }
        if used(recommended) > budget * 0.7 {
            // Nothing fits comfortably; take the largest that fits at all, if any.
            let fitting = Self.contextSteps.filter { $0 <= cap && used($0) <= budget }
            recommended = fitting.last ?? recommended
        }

        // Continuous safe maximum at 85% of budget, rounded down to 1K.
        let room = budget * 0.85 - Double(weights)
        var safeMax = perToken > 0 ? Int(room / perToken) : 0
        safeMax = max(0, min(safeMax, native)) / 1024 * 1024

        let verdict: FitVerdict
        if used(Self.contextSteps[0]) > budget { verdict = .wontFit }
        else if used(recommended) <= budget * 0.7 { verdict = .comfortable }
        else { verdict = .tight }

        let kv = UInt64(perToken * Double(recommended))
        return Assessment(model: m, verdict: verdict, weightsBytes: weights,
                          recommendedContext: recommended, safeMaxContext: safeMax,
                          kvBytesAtRecommended: kv,
                          headroomBytes: Int64(budget) - Int64(weights) - Int64(kv),
                          tokensPerSecond: tokensPerSecond(m), quality: quality(m, task: task))
    }

    public func recommend(from models: [ModelMetadata], task: AdvisorTask) -> Recommendations {
        let all = models.map { assess($0, task: task) }.filter { $0.verdict != .wontFit }
        let usable = all.filter { $0.quality > 20 }
        var picked = Set<String>()

        func pick(_ list: [Assessment], by key: (Assessment) -> Double) -> Assessment? {
            let best = list.filter { !picked.contains($0.id) }.max { key($0) < key($1) }
            if let best { picked.insert(best.id) }
            return best
        }

        let comfortable = usable.filter { $0.verdict == .comfortable && $0.tokensPerSecond >= 20 }
        let overall = pick(comfortable) { $0.quality + $0.tokensPerSecond / 1000 }
        let quality = pick(usable) { $0.quality }
        let fast = pick(usable.filter { $0.quality >= 50 }) { $0.tokensPerSecond }
        return Recommendations(bestOverall: overall, highestQuality: quality, fastest: fast)
    }
}

public func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

public func formatContext(_ tokens: Int) -> String {
    tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)"
}
