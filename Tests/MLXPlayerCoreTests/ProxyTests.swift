import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MLXPlayerCore

final class ProxyTests: XCTestCase {
    var backend: ManagedProcess?
    var proxy: LazyProxy?

    override func tearDown() {
        backend?.terminate(grace: 1)
        proxy?.stop()
    }

    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake_backend.py")
    }

    func freePort() throws -> Int {
        let l = TCPListener(host: "127.0.0.1", port: 0)
        try l.start { TCP.close($0) }
        defer { l.stop() }
        return l.port
    }

    func startBackend(port: Int) async throws {
        let p = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                               arguments: ["-I", Self.fixture.path, String(port)], environment: [:]) { _ in }
        try p.start()
        backend = p
        for _ in 0..<50 {
            if TCP.connect(host: "127.0.0.1", port: port).map({ TCP.close($0); return true }) == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("backend did not start")
    }

    func post(_ port: Int, body: String, ua: String = "claude-cli/1.0") async throws -> (Int, String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as! HTTPURLResponse).statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    final class Counter: @unchecked Sendable {
        var ensureCalls = 0
        var records: [UsageRecord] = []
        let lock = NSLock()
    }

    func makeProxy(counter: Counter, backendPort: Int, limit: Int = 0, backendUp: Bool = true) throws -> Int {
        let publicPort = try freePort()
        let p = LazyProxy(port: publicPort)
        p.backendPort = backendPort
        p.contextLimit = limit
        p.servedModel = "fake"
        p.ensureBackend = { _ in counter.lock.withLock { counter.ensureCalls += 1 }; return true }
        p.isBackendRunning = { backendUp }
        p.onRecord = { r in counter.lock.withLock { counter.records.append(r) } }
        try p.start()
        proxy = p
        return publicPort
    }

    func testForwardsPlainRequestAndMetersUsage() async throws {
        let bp = try freePort()
        try await startBackend(port: bp)
        let c = Counter()
        let port = try makeProxy(counter: c, backendPort: bp)
        let (status, body) = try await post(port, body: #"{"model":"fake","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("hello"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.ensureCalls, 1)
        XCTAssertEqual(c.records.count, 1)
        XCTAssertEqual(c.records[0].tokensIn, 3)
        XCTAssertEqual(c.records[0].tokensOut, 2)
        XCTAssertEqual(c.records[0].client, "Claude Code")
    }

    func testStreamsSSEAndInjectsUsageOption() async throws {
        let bp = try freePort()
        try await startBackend(port: bp)
        let c = Counter()
        let port = try makeProxy(counter: c, backendPort: bp)
        let (status, body) = try await post(port, body: #"{"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("t4"))
        XCTAssertTrue(body.contains("[DONE]"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(c.records.first?.tokensOut, 5)   // came from the injected include_usage
        XCTAssertEqual(c.records.first?.tokensIn, 7)
    }

    func testContextLimitRejectsWithoutStartingModel() async throws {
        let bp = try freePort()
        let c = Counter()
        let port = try makeProxy(counter: c, backendPort: bp, limit: 50)
        let long = String(repeating: "word ", count: 400)
        let (status, body) = try await post(port, body: #"{"model":"fake","messages":[{"role":"user","content":"\#(long)"}]}"#)
        XCTAssertEqual(status, 400)
        XCTAssertTrue(body.contains("context_length_exceeded"))
        XCTAssertEqual(c.ensureCalls, 0)
    }

    func testModelListAndHealthDoNotLoadModel() async throws {
        let bp = try freePort()
        let c = Counter()
        let port = try makeProxy(counter: c, backendPort: bp, backendUp: false)
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("fake"))
        let (h, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertTrue(String(data: h, encoding: .utf8)!.contains("model_loaded"))
        XCTAssertEqual(c.ensureCalls, 0)
    }

    func testBackendDownGives502() async throws {
        let bp = try freePort()   // nothing listening
        let c = Counter()
        let port = try makeProxy(counter: c, backendPort: bp)
        let (status, _) = try await post(port, body: #"{"model":"fake","messages":[]}"#)
        XCTAssertEqual(status, 502)
    }

    func testControlServerAuth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: dir)
        let server = try ControlServer { method, path, body in (200, ["path": path, "model": body["model"] as? String ?? ""]) }
        try server.start(writingTo: paths.controlFile)
        defer { server.stop() }
        let client = ControlClient(paths: paths)
        let resp = try await client.call("POST", "/download", body: ["model": "m/x"])
        XCTAssertEqual(resp["path"] as? String, "/download")
        XCTAssertEqual(resp["model"] as? String, "m/x")

        // Wrong token is rejected.
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/status")!)
        req.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, r) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((r as! HTTPURLResponse).statusCode, 401)
    }
}
