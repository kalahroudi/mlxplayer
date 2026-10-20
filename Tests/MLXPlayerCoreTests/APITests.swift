import XCTest
@testable import MLXPlayerCore

final class APITests: XCTestCase {
    func testHeadParsing() {
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: 12\r\nUser-Agent: claude-cli/1.0\r\nTransfer-Encoding: chunked"
        let head = HTTPRequestHead.parse(Data(raw.utf8))!
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/v1/chat/completions")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertTrue(head.isChunked)
        XCTAssertEqual(head.header("user-agent"), "claude-cli/1.0")
        let out = String(data: head.serialized(body: Data("hi".utf8)), encoding: .utf8)!
        XCTAssertTrue(out.contains("Connection: close"))
        XCTAssertTrue(out.contains("Content-Length: 2"))
        XCTAssertFalse(out.contains("chunked"))
    }

    func testMetering() {
        let body = Data(#"{"model":"m/x","stream":true,"messages":[{"role":"user","content":"hello world hello world"}]}"#.utf8)
        XCTAssertEqual(APIMeter.requestedModel(body: body), "m/x")
        XCTAssertTrue(APIMeter.isStreaming(body: body))
        XCTAssertEqual(APIMeter.estimatePromptTokens(body: body), 8)
        let tail = Data(#"data: {"usage":{"prompt_tokens":11,"completion_tokens":42}}"#.utf8)
        XCTAssertEqual(APIMeter.usage(inResponseTail: tail)?.completion, 42)
        XCTAssertEqual(APIMeter.usage(inResponseTail: tail)?.prompt, 11)
        XCTAssertNil(APIMeter.usage(inResponseTail: Data("nothing".utf8)))
    }

    func testClientNames() {
        XCTAssertEqual(APIMeter.clientName(userAgent: "claude-cli/2.0 (external)"), "Claude Code")
        XCTAssertEqual(APIMeter.clientName(userAgent: "curl/8.4"), "curl")
        XCTAssertEqual(APIMeter.clientName(userAgent: "OpenAI/Python 1.3"), "OpenAI SDK")
        XCTAssertEqual(APIMeter.clientName(userAgent: nil), "Unknown")
    }

    func testUsageStoreSummaries() {
        let store = UsageStore(url: nil)
        let now = Date()
        store.record(UsageRecord(timestamp: now, model: "a", client: "Claude Code", tokensIn: 1000, tokensOut: 100, durationMs: 2000, firstTokenMs: 500))
        store.record(UsageRecord(timestamp: now, model: "a", client: "Cursor", tokensIn: 500, tokensOut: 50, durationMs: 1500, firstTokenMs: 500))
        store.record(UsageRecord(timestamp: now.addingTimeInterval(-86_400 * 3), model: "b", client: "curl", tokensIn: 10, tokensOut: 5, durationMs: 100, status: 500))
        let today = store.summary(.today, now: now)
        XCTAssertEqual(today.requests, 2)
        XCTAssertEqual(today.tokensIn, 1500)
        XCTAssertEqual(today.byClient.first?.name, "Claude Code")
        XCTAssertEqual(today.buckets.count, 24)
        XCTAssertEqual(today.averageTokensPerSecond, 60, accuracy: 15)   // 100/1.5s and 50/1.0s
        let week = store.summary(.week, now: now)
        XCTAssertEqual(week.requests, 3)
        XCTAssertEqual(week.errors, 1)
        XCTAssertEqual(week.buckets.count, 7)
        XCTAssertTrue(store.csv(.week, now: now).hasPrefix("timestamp,model"))
    }

    func testUsageStorePersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        UsageStore(url: url).record(UsageRecord(model: "m", client: "c", tokensIn: 1, tokensOut: 2, durationMs: 3))
        XCTAssertEqual(UsageStore(url: url).summary(.today).requests, 1)
    }

    func testHFParse() {
        let json = #"[{"id":"mlx-community/Qwen3-8B-4bit","downloads":1234,"likes":5,"tags":["mlx","text-generation"],"lastModified":"2025-09-01T10:00:00.000Z","usedStorage":4600000000}]"#
        let models = HuggingFaceClient.parseSearch(Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].downloads, 1234)
        XCTAssertEqual(models[0].diskBytes, 4_600_000_000)
        XCTAssertNotNil(models[0].lastModified)
        XCTAssertEqual(models[0].bits, 4)
    }

    func testControlInfoRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let info = ControlInfo.make(port: 1234)
        try info.write(to: url)
        XCTAssertEqual(ControlInfo.read(from: url), info)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testLibraryScan() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = hub.appendingPathComponent("models--mlx-community--Qwen3-8B-4bit")
        let snap = repo.appendingPathComponent("snapshots/abc")
        let blobs = repo.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(#"{"num_hidden_layers":36,"num_attention_heads":32,"num_key_value_heads":8,"hidden_size":4096}"#.utf8)
            .write(to: snap.appendingPathComponent("config.json"))
        try Data(count: 5000).write(to: blobs.appendingPathComponent("abc123"))
        let found = ModelLibrary.scan(hub: hub)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(found[0].meta.layers, 36)
        XCTAssertEqual(found[0].sizeBytes, 5000)
        try Data(count: 1).write(to: blobs.appendingPathComponent("zzz.incomplete"))
        XCTAssertTrue(ModelLibrary.scan(hub: hub).isEmpty)
    }
}
