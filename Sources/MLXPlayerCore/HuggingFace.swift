import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SearchSort: String, CaseIterable, Sendable {
    case downloads, likes, recent, trending

    public var label: String {
        switch self {
        case .downloads: return "Downloads"
        case .likes: return "Likes"
        case .recent: return "Recently updated"
        case .trending: return "Trending"
        }
    }

    var apiValue: String {
        switch self {
        case .downloads: return "downloads"
        case .likes: return "likes"
        case .recent: return "lastModified"
        case .trending: return "trendingScore"
        }
    }
}

public enum ModelFamily: String, CaseIterable, Sendable {
    case qwen = "Qwen", llama = "Llama", gemma = "Gemma", mistral = "Mistral", deepseek = "DeepSeek", phi = "Phi", glm = "GLM"

    public static func detect(_ id: String) -> ModelFamily? {
        let l = id.lowercased()
        return allCases.first { l.contains($0.rawValue.lowercased()) }
    }
}

/// Client-side filters applied to search results.
public struct ModelFilter: Equatable, Sendable {
    public enum SizeBucket: String, CaseIterable, Sendable {
        case under3 = "Under 3B", b3to8 = "3B – 8B", b8to14 = "8B – 14B", b14to35 = "14B – 35B", over35 = "35B and up"

        func contains(_ b: Double) -> Bool {
            switch self {
            case .under3: return b < 3
            case .b3to8: return b >= 3 && b < 8
            case .b8to14: return b >= 8 && b < 14
            case .b14to35: return b >= 14 && b < 35
            case .over35: return b >= 35
            }
        }
    }

    public var sizes: Set<SizeBucket> = []
    public var bits: Set<Int> = []
    public var capabilities: Set<Capability> = []
    public var families: Set<ModelFamily> = []
    public var variant: ModelVariant = .standard
    public var fitsMyMac = false

    public init() {}

    public func apply(_ models: [ModelMetadata], advisor: Advisor?, task: AdvisorTask = .chat) -> [ModelMetadata] {
        models.filter { m in
            if m.variant != variant { return false }
            if !sizes.isEmpty {
                guard let b = m.totalParamsB, sizes.contains(where: { $0.contains(b) }) else { return false }
            }
            if !bits.isEmpty, !bits.contains(m.bits) { return false }
            if !capabilities.isEmpty, capabilities.isDisjoint(with: m.capabilities) { return false }
            if !families.isEmpty {
                guard let f = ModelFamily.detect(m.id), families.contains(f) else { return false }
            }
            if fitsMyMac, let advisor, advisor.assess(m, task: task).verdict == .wontFit { return false }
            return true
        }
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var text = ""
    public var publisher: String? = "mlx-community"
    public var sort: SearchSort = .downloads
    public var variant: ModelVariant = .standard
    public var limit = 50

    public init(text: String = "", publisher: String? = "mlx-community", sort: SearchSort = .downloads,
                variant: ModelVariant = .standard, limit: Int = 50) {
        self.text = text
        self.publisher = publisher
        self.sort = sort
        self.variant = variant
        self.limit = limit
    }
}

public final class HuggingFaceClient: @unchecked Sendable {
    private let session: URLSession
    private let token: String?
    private let base = URL(string: "https://huggingface.co")!

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("MLXPlayer/1.0", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    public func search(_ q: SearchQuery) async throws -> [ModelMetadata] {
        var comps = URLComponents(url: base.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "filter", value: "mlx"),
            .init(name: "sort", value: q.sort.apiValue),
            .init(name: "direction", value: "-1"),
            .init(name: "limit", value: String(q.limit)),
        ]
        // Variant models live under many community authors, so search by keyword instead of publisher.
        var text = q.text
        switch q.variant {
        case .standard:
            if let pub = q.publisher { items.append(.init(name: "author", value: pub)) }
        case .uncensored:
            text = (text + " uncensored").trimmingCharacters(in: .whitespaces)
        case .abliterated:
            text = (text + " abliterated").trimmingCharacters(in: .whitespaces)
        }
        if !text.isEmpty { items.append(.init(name: "search", value: text)) }
        for field in ["downloads", "likes", "lastModified", "tags", "usedStorage", "pipeline_tag"] {
            items.append(.init(name: "expand[]", value: field))
        }
        comps.queryItems = items
        let (data, resp) = try await session.data(for: request(comps.url!))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw HFError.http(http.statusCode)
        }
        return Self.parseSearch(data)
    }

    static func parseSearch(_ data: Data) -> [ModelMetadata] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        return arr.compactMap { item in
            guard let id = (item["id"] as? String) ?? (item["modelId"] as? String) else { return nil }
            var m = ModelMetadata.fromName(id)
            m.downloads = item["downloads"] as? Int ?? 0
            m.likes = item["likes"] as? Int ?? 0
            m.tags = item["tags"] as? [String] ?? []
            if let s = item["lastModified"] as? String { m.lastModified = iso.date(from: s) ?? isoPlain.date(from: s) }
            if let used = item["usedStorage"] as? Int, used > 0 { m.diskBytes = UInt64(used) }
            else if let used = item["usedStorage"] as? Double, used > 0 { m.diskBytes = UInt64(used) }
            return m
        }
    }

    public func config(for id: String) async -> ModelConfig? {
        let url = base.appendingPathComponent("\(id)/resolve/main/config.json")
        guard let (data, resp) = try? await session.data(for: request(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ModelConfig.parse(data)
    }

    /// Fills in layers, KV heads and context from config.json for more accurate memory estimates.
    public func enrich(_ models: [ModelMetadata]) async -> [ModelMetadata] {
        await withTaskGroup(of: (Int, ModelMetadata).self) { group in
            for (i, m) in models.enumerated() {
                group.addTask { [self] in
                    guard let cfg = await config(for: m.id) else { return (i, m) }
                    return (i, m.applying(config: cfg))
                }
            }
            var out = models
            for await (i, m) in group { out[i] = m }
            return out
        }
    }

    /// Total bytes of all files in a repo, for download progress.
    public func repoSize(_ id: String) async -> UInt64? {
        let url = base.appendingPathComponent("api/models/\(id)/tree/main")
        guard let (data, _) = try? await session.data(for: request(url)),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var total: UInt64 = 0
        for f in arr {
            if let lfs = f["lfs"] as? [String: Any], let size = lfs["size"] as? Int { total += UInt64(size) }
            else if let size = f["size"] as? Int { total += UInt64(size) }
        }
        return total > 0 ? total : nil
    }
}

public enum HFError: Error, LocalizedError {
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .http(let c): return "Hugging Face returned HTTP \(c)."
        }
    }
}
