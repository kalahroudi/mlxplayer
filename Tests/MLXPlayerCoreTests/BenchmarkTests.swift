import XCTest
@testable import MLXPlayerCore

final class BenchmarkTests: XCTestCase {
    func testHasContent() {
        XCTAssertTrue(SpeedBenchmark.hasContent(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#))
        XCTAssertTrue(SpeedBenchmark.hasContent(#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#))
        XCTAssertFalse(SpeedBenchmark.hasContent(#"data: {"choices":[{"delta":{"content":""}}]}"#))
        XCTAssertFalse(SpeedBenchmark.hasContent(#"data: {"choices":[],"usage":{"prompt_tokens":7}}"#))
        XCTAssertFalse(SpeedBenchmark.hasContent("data: [DONE]"))
        XCTAssertFalse(SpeedBenchmark.hasContent(": keep-alive"))
    }

    func testSummarize() {
        let start = Date(timeIntervalSince1970: 100)
        // First token after 0.5 s, then 10 more over 1 s: 10 t/s.
        let times = (0...10).map { start.addingTimeInterval(0.5 + Double($0) * 0.1) }
        let s = SpeedBenchmark.summarize(chunkTimes: times, start: start)
        XCTAssertEqual(s?.tokensPerSecond ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(s?.firstTokenMs, 500)
        XCTAssertNil(SpeedBenchmark.summarize(chunkTimes: Array(times.prefix(5)), start: start), "too few tokens")
    }

    func testCalibrationFactorIsMedianAndClamped() {
        let chip = "Apple Test"
        let est: (ModelMetadata) -> Double = { _ in 100 }
        func r(_ id: String, _ tps: Double) -> BenchmarkResult { BenchmarkResult(modelID: id, decodeTokensPerSecond: tps, firstTokenMs: 1, tokens: 100, chip: chip) }
        XCTAssertEqual(SpeedCalibration.factor(results: [], chip: chip, estimate: est), 1)
        XCTAssertEqual(SpeedCalibration.factor(results: [r("a/x-4bit", 50), r("a/y-4bit", 60), r("a/z-4bit", 400)], chip: chip, estimate: est), 0.6, accuracy: 0.001)
        XCTAssertEqual(SpeedCalibration.factor(results: [r("a/x-4bit", 5)], chip: chip, estimate: est), 0.25, accuracy: 0.001)
        XCTAssertEqual(SpeedCalibration.factor(results: [r("a/x-4bit", 50)], chip: "Other Chip", estimate: est), 1, "other chips are ignored")
    }

    func testTinyModelsDoNotCalibrateLargeOnes() {
        let est: (ModelMetadata) -> Double = { _ in 1000 }
        let tiny = BenchmarkResult(modelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", decodeTokensPerSecond: 379, firstTokenMs: 800, tokens: 160, chip: "C")
        XCTAssertEqual(SpeedCalibration.factor(results: [tiny], chip: "C", estimate: est), 1)
    }

    func testAdvisorUsesMeasuredThenCalibration() {
        var hw = HardwareProbe.current(); hw.bandwidthGBs = 400
        var advisor = Advisor(hardware: hw)
        let m = ModelMetadata.fromName("mlx-community/Qwen3-8B-4bit")
        let raw = advisor.tokensPerSecond(m)
        advisor.speedCalibration = 0.5
        XCTAssertEqual(advisor.tokensPerSecond(m), raw * 0.5, accuracy: 0.001)
        advisor.measuredSpeeds[m.id] = 77
        XCTAssertEqual(advisor.tokensPerSecond(m), 77)
    }

    func testBenchmarkAgainstFakeBackend() async throws {
        let backend = BenchmarkBackend()
        let port = try await backend.start()
        defer { backend.stop() }
        let r = try await SpeedBenchmark.run(endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!, model: "fake", maxTokens: 30, chip: "Test")
        XCTAssertEqual(r.tokens, 30)
        XCTAssertGreaterThan(r.decodeTokensPerSecond, 10)
        XCTAssertLessThan(r.decodeTokensPerSecond, 80, "backend emits about 50 tokens per second")
        XCTAssertGreaterThanOrEqual(r.firstTokenMs, 0)
    }

    func testBenchmarkReportsTooShort() async throws {
        let backend = BenchmarkBackend()
        let port = try await backend.start()
        defer { backend.stop() }
        do {
            _ = try await SpeedBenchmark.run(endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!, model: "fake", maxTokens: 3, chip: "Test")
            XCTFail("expected tooShort")
        } catch let e as BenchmarkError {
            XCTAssertEqual(e, .tooShort(3))
        }
    }

    func testClientNameForBenchmark() {
        XCTAssertEqual(APIMeter.clientName(userAgent: SpeedBenchmark.userAgent), "Benchmark")
    }
}

/// Runs the fake OpenAI backend used by the proxy tests.
private final class BenchmarkBackend: @unchecked Sendable {
    private var process: ManagedProcess?

    func start() async throws -> Int {
        let l = TCPListener(host: "127.0.0.1", port: 0)
        try l.start { TCP.close($0) }
        let port = l.port
        l.stop()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake_backend.py")
        let p = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                               arguments: ["-I", fixture.path, String(port)], environment: [:]) { _ in }
        try p.start()
        process = p
        for _ in 0..<50 {
            if TCP.connect(host: "127.0.0.1", port: port).map({ TCP.close($0); return true }) == true { return port }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("backend did not start")
    }

    func stop() { process?.killNow() }
}

/// Runs against a real mlx_lm.server. Skipped unless MLX_LIVE_MODEL is set, for example
/// `MLX_LIVE_MODEL=mlx-community/Qwen2.5-0.5B-Instruct-4bit swift test --filter LiveBenchmarkTests`.
final class LiveBenchmarkTests: XCTestCase {
    func testRealServer() async throws {
        guard let model = ProcessInfo.processInfo.environment["MLX_LIVE_MODEL"] else { throw XCTSkip("MLX_LIVE_MODEL not set") }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MLX Player/venv/bin/mlx_lm.server")
        guard FileManager.default.isExecutableFile(atPath: support.path) else { throw XCTSkip("mlx-lm is not installed") }
        let l = TCPListener(host: "127.0.0.1", port: 0)
        try l.start { TCP.close($0) }
        let port = l.port
        l.stop()
        let p = ManagedProcess(executable: support, arguments: ["--model", model, "--port", String(port)], environment: ProcessInfo.processInfo.environment) { _ in }
        try p.start()
        defer { p.terminate() }
        for _ in 0..<120 {
            if TCP.connect(host: "127.0.0.1", port: port).map({ TCP.close($0); return true }) == true { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let r = try await SpeedBenchmark.run(endpoint: URL(string: "http://127.0.0.1:\(port)/v1")!, model: model, chip: HardwareProbe.current().chip)
        print("LIVE BENCHMARK:", r)
        XCTAssertGreaterThan(r.decodeTokensPerSecond, 5)
        XCTAssertGreaterThan(r.tokens, 20)
    }
}
