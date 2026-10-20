import Foundation

public struct UsageRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var model: String
    public var client: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var durationMs: Int
    public var firstTokenMs: Int?
    public var status: Int

    public init(timestamp: Date = Date(), model: String, client: String, tokensIn: Int, tokensOut: Int,
                durationMs: Int, firstTokenMs: Int? = nil, status: Int = 200) {
        self.timestamp = timestamp
        self.model = model
        self.client = client
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.durationMs = durationMs
        self.firstTokenMs = firstTokenMs
        self.status = status
    }
}

public enum UsageRange: String, CaseIterable, Sendable {
    case today, week, month

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    func start(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
    }
}

public struct UsageSummary: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var requests = 0
        public var tokensIn = 0
        public var tokensOut = 0
        public var tokensPerSecond: Double = 0
    }

    public var requests = 0
    public var errors = 0
    public var tokensIn = 0
    public var tokensOut = 0
    public var averageTokensPerSecond: Double = 0
    public var peakTokensPerSecond: Double = 0
    public var medianFirstTokenMs: Int?
    /// Tokens (in, out) per bucket: 24 hours for Today, one per day otherwise.
    public var buckets: [(label: String, tokensIn: Int, tokensOut: Int)] = []
    public var byClient: [Row] = []
    public var byModel: [Row] = []

    public init() {}

    public static func == (l: UsageSummary, r: UsageSummary) -> Bool {
        l.requests == r.requests && l.tokensIn == r.tokensIn && l.tokensOut == r.tokensOut
    }
}

/// Append-only request log (JSON lines) with in-memory aggregation.
public final class UsageStore: @unchecked Sendable {
    private let url: URL?
    private var records: [UsageRecord] = []
    private let lock = NSLock()
    private let retentionDays = 30

    public init(url: URL?) {
        self.url = url
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let lines = text.split(separator: "\n")
        records = lines.compactMap { line in
            try? dec.decode(UsageRecord.self, from: Data(line.utf8))
        }.filter { $0.timestamp >= cutoff }
        // The file is append-only, so drop expired rows from disk too, otherwise it grows forever.
        if records.count < lines.count { compact() }
    }

    /// Rewrites the log with only the retained records.
    func compact() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let rows = lock.withLock { records }
        var out = Data()
        for r in rows { if let d = try? enc.encode(r) { out.append(d); out.append(0x0A) } }
        try? out.write(to: url, options: .atomic)
    }

    private var appendsSinceCompact = 0

    public func record(_ r: UsageRecord) {
        let due: Bool = lock.withLock {
            records.append(r)
            appendsSinceCompact += 1
            guard appendsSinceCompact >= 1000 else { return false }
            appendsSinceCompact = 0
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            records.removeAll { $0.timestamp < cutoff }
            return true
        }
        guard let url else { return }
        if due { compact(); return }  // the rewrite already includes this record
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(r) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public func summary(_ range: UsageRange, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let start = range.start(now: now, calendar: calendar)
        let rows = lock.withLock { records.filter { $0.timestamp >= start } }
        var s = UsageSummary()
        s.requests = rows.count
        s.errors = rows.filter { $0.status >= 400 }.count
        s.tokensIn = rows.reduce(0) { $0 + $1.tokensIn }
        s.tokensOut = rows.reduce(0) { $0 + $1.tokensOut }

        func speed(_ r: UsageRecord) -> Double? {
            let genMs = Double(r.durationMs - (r.firstTokenMs ?? 0))
            guard r.tokensOut > 0, genMs > 50 else { return nil }
            return Double(r.tokensOut) / (genMs / 1000)
        }
        let speeds = rows.compactMap(speed)
        s.averageTokensPerSecond = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        s.peakTokensPerSecond = speeds.max() ?? 0
        let ttft = rows.compactMap(\.firstTokenMs).sorted()
        s.medianFirstTokenMs = ttft.isEmpty ? nil : ttft[ttft.count / 2]

        if range == .today {
            var hours = [(Int, Int)](repeating: (0, 0), count: 24)
            for r in rows {
                let h = calendar.component(.hour, from: r.timestamp)
                hours[h].0 += r.tokensIn
                hours[h].1 += r.tokensOut
            }
            s.buckets = hours.enumerated().map { (String(format: "%02d:00", $0.offset), $0.element.0, $0.element.1) }
        } else {
            let days = range == .week ? 7 : 30
            let startDay = calendar.startOfDay(for: start)
            var totals = [(Int, Int)](repeating: (0, 0), count: days)
            for r in rows {
                let d = calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: r.timestamp)).day ?? 0
                if d >= 0, d < days { totals[d].0 += r.tokensIn; totals[d].1 += r.tokensOut }
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            s.buckets = totals.enumerated().map { i, t in
                let day = calendar.date(byAdding: .day, value: i, to: startDay) ?? startDay
                return (fmt.string(from: day), t.0, t.1)
            }
        }

        func group(_ key: (UsageRecord) -> String) -> [UsageSummary.Row] {
            Dictionary(grouping: rows, by: key).map { name, items in
                var row = UsageSummary.Row(name: name)
                row.requests = items.count
                row.tokensIn = items.reduce(0) { $0 + $1.tokensIn }
                row.tokensOut = items.reduce(0) { $0 + $1.tokensOut }
                let sp = items.compactMap(speed)
                row.tokensPerSecond = sp.isEmpty ? 0 : sp.reduce(0, +) / Double(sp.count)
                return row
            }.sorted { ($0.tokensIn + $0.tokensOut) > ($1.tokensIn + $1.tokensOut) }
        }
        s.byClient = group(\.client)
        s.byModel = group(\.model)
        return s
    }

    /// CSV export of raw records in the range.
    public func csv(_ range: UsageRange, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = range.start(now: now, calendar: calendar)
        let rows = lock.withLock { records.filter { $0.timestamp >= start } }
        let iso = ISO8601DateFormatter()
        var out = "timestamp,model,client,tokens_in,tokens_out,duration_ms,first_token_ms,status\n"
        for r in rows {
            out += "\(iso.string(from: r.timestamp)),\(r.model),\(r.client),\(r.tokensIn),\(r.tokensOut),\(r.durationMs),\(r.firstTokenMs.map(String.init) ?? ""),\(r.status)\n"
        }
        return out
    }
}
