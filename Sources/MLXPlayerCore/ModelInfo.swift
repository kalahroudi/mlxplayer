import Foundation

public enum ModelVariant: String, Codable, CaseIterable, Sendable {
    case standard, uncensored, abliterated

    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .uncensored: return "Uncensored"
        case .abliterated: return "Abliterated"
        }
    }
}

public enum Capability: String, Codable, CaseIterable, Sendable {
    case chat, code, reasoning, vision, embeddings
}

public struct ModelMetadata: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var totalParamsB: Double?
    public var activeParamsB: Double?
    public var bits: Int
    public var diskBytes: UInt64
    public var layers: Int?
    public var kvHeads: Int?
    public var headDim: Int?
    public var nativeContext: Int?
    public var downloads: Int
    public var likes: Int
    public var lastModified: Date?
    public var tags: [String]

    public init(id: String, totalParamsB: Double? = nil, activeParamsB: Double? = nil, bits: Int = 16,
                diskBytes: UInt64 = 0, layers: Int? = nil, kvHeads: Int? = nil, headDim: Int? = nil,
                nativeContext: Int? = nil, downloads: Int = 0, likes: Int = 0, lastModified: Date? = nil,
                tags: [String] = []) {
        self.id = id
        self.totalParamsB = totalParamsB
        self.activeParamsB = activeParamsB
        self.bits = bits
        self.diskBytes = diskBytes
        self.layers = layers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.nativeContext = nativeContext
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.tags = tags
    }

    /// Builds metadata from a repo id alone, reading size and quantization from the name.
    public static func fromName(_ id: String) -> ModelMetadata {
        let parsed = NameParser.parse(id)
        var meta = ModelMetadata(id: id, totalParamsB: parsed.totalB, activeParamsB: parsed.activeB, bits: parsed.bits)
        if let b = parsed.totalB { meta.diskBytes = UInt64(b * 1e9 * (Double(parsed.bits) + (parsed.bits < 16 ? 0.5 : 0)) / 8) }
        return meta
    }

    public var publisher: String { id.split(separator: "/").first.map(String.init) ?? "" }
    public var displayName: String { id.split(separator: "/").last.map(String.init) ?? id }
    public var isMoE: Bool { (activeParamsB ?? 0) > 0 && (activeParamsB ?? 0) < (totalParamsB ?? 0) }
    public var variant: ModelVariant { NameParser.variant(id: id, tags: tags) }
    public var capabilities: Set<Capability> { NameParser.capabilities(id: id, tags: tags) }

    /// Bytes of fp16 KV cache per token of context. Uses the real config when known.
    public func kvBytesPerToken(elementBytes: Double = 2) -> Double {
        if let l = layers, let h = kvHeads, let d = headDim {
            return Double(2 * l * h * d) * elementBytes
        }
        let b = totalParamsB ?? 8
        return 40_000 * pow(b, 0.55) * (elementBytes / 2)
    }

    public var hasExactKV: Bool { layers != nil && kvHeads != nil && headDim != nil }

    public func applying(config: ModelConfig) -> ModelMetadata {
        var copy = self
        copy.layers = config.layers ?? layers
        copy.kvHeads = config.kvHeads ?? kvHeads
        copy.headDim = config.headDim ?? headDim
        copy.nativeContext = config.maxPositionEmbeddings ?? nativeContext
        return copy
    }
}

/// The handful of config.json fields that drive memory use.
public struct ModelConfig: Equatable, Sendable {
    public var layers: Int?
    public var kvHeads: Int?
    public var headDim: Int?
    public var maxPositionEmbeddings: Int?

    public init(layers: Int? = nil, kvHeads: Int? = nil, headDim: Int? = nil, maxPositionEmbeddings: Int? = nil) {
        self.layers = layers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.maxPositionEmbeddings = maxPositionEmbeddings
    }

    public static func parse(_ data: Data) -> ModelConfig? {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Vision-language models nest the language model under text_config.
        if let text = json["text_config"] as? [String: Any] {
            json = json.merging(text) { _, new in new }
        }
        func int(_ key: String) -> Int? {
            if let v = json[key] as? Int { return v }
            if let v = json[key] as? Double { return Int(v) }
            return nil
        }
        let heads = int("num_attention_heads")
        let kv = int("num_key_value_heads") ?? heads
        var dim = int("head_dim")
        if dim == nil, let hidden = int("hidden_size"), let h = heads, h > 0 { dim = hidden / h }
        return ModelConfig(layers: int("num_hidden_layers"), kvHeads: kv, headDim: dim,
                           maxPositionEmbeddings: int("max_position_embeddings"))
    }
}

public enum NameParser {
    public struct Parsed: Equatable {
        public var totalB: Double?
        public var activeB: Double?
        public var bits: Int
    }

    public static func parse(_ id: String) -> Parsed {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return Parsed(totalB: totalParams(name), activeB: activeParams(name), bits: bits(name))
    }

    static func bits(_ name: String) -> Int {
        let lower = name.lowercased()
        if let m = firstMatch(#"(\d+)[-_ ]?bit"#, in: lower), let n = Int(m) { return n }
        if lower.contains("mxfp4") || lower.contains("nvfp4") { return 4 }
        if lower.contains("bf16") || lower.contains("fp16") { return 16 }
        if lower.contains("fp8") { return 8 }
        if let m = firstMatch(#"(?:^|[-_])q(\d)(?:[-_]|$)"#, in: lower), let n = Int(m) { return n }
        return 16
    }

    static func totalParams(_ name: String) -> Double? {
        firstMatch(#"(?<![A-Za-z0-9.])(\d+(?:\.\d+)?)[Bb](?![A-Za-z])"#, in: name).flatMap(Double.init)
    }

    static func activeParams(_ name: String) -> Double? {
        firstMatch(#"(?<![A-Za-z])A(\d+(?:\.\d+)?)B"#, in: name).flatMap(Double.init)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public static func variant(id: String, tags: [String]) -> ModelVariant {
        let hay = (id + " " + tags.joined(separator: " ")).lowercased()
        if hay.contains("abliterat") || hay.contains("lorablat") || hay.contains("heretic") { return .abliterated }
        if hay.contains("uncensored") || hay.contains("unfiltered") || hay.contains("dolphin") { return .uncensored }
        return .standard
    }

    public static func capabilities(id: String, tags: [String]) -> Set<Capability> {
        let hay = (id + " " + tags.joined(separator: " ")).lowercased()
        var caps: Set<Capability> = []
        if hay.contains("coder") || hay.contains("code") || hay.contains("devstral") { caps.insert(.code) }
        if hay.contains("-r1") || hay.contains("reason") || hay.contains("thinking") || hay.contains("qwq")
            || hay.contains("deepseek-r1") { caps.insert(.reasoning) }
        if hay.contains("-vl") || hay.contains("vision") || hay.contains("llava") || hay.contains("pixtral")
            || hay.contains("image-text-to-text") { caps.insert(.vision) }
        if hay.contains("embed") || hay.contains("bge") || hay.contains("sentence-similarity") { caps.insert(.embeddings) }
        if caps.isEmpty || hay.contains("instruct") || hay.contains("chat") || hay.contains("-it") { caps.insert(.chat) }
        return caps
    }
}
