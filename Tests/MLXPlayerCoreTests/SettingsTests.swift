import XCTest
@testable import MLXPlayerCore

final class SettingsTests: XCTestCase {
    func testCommandMatchesUsersExample() {
        var s = ServerSettings(modelID: "mlx-community/Qwen2.5-14B-Instruct-4bit")
        s.chatTemplateArgs = #"{"enable_thinking":false}"#
        let args = s.arguments()
        XCTAssertEqual(args[0], "--model")
        XCTAssertEqual(args[1], "mlx-community/Qwen2.5-14B-Instruct-4bit")
        XCTAssertTrue(args.contains("--chat-template-args"))
        XCTAssertEqual(args[args.firstIndex(of: "--chat-template-args")! + 1], #"{"enable_thinking":false}"#)
        XCTAssertEqual(args[args.firstIndex(of: "--port")! + 1], "8080")
    }

    func testBackendStaysOnLoopbackWhenSharedOnTheNetwork() {
        var s = ServerSettings(modelID: "m")
        s.host = "0.0.0.0"
        let args = s.arguments()
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
    }

    func testUnsupportedFlagsAreDropped() {
        var s = ServerSettings(modelID: "m/x")
        s.draftModel = "m/draft"
        let supported: Set<String> = ["--model", "--port", "--host", "--temp"]
        let args = s.arguments(supported: supported)
        XCTAssertFalse(args.contains("--draft-model"))
        XCTAssertFalse(args.contains("--top-k"))
        XCTAssertTrue(args.contains("--temp"))
    }

    /// Flags from `mlx_lm.server --help` on mlx-lm 0.32.2 (no --max-kv-size).
    func testEveryEmittedFlagExistsInMLXLM() {
        let real: Set<String> = ["--model", "--adapter-path", "--host", "--port", "--allowed-origins", "--draft-model",
            "--num-draft-tokens", "--trust-remote-code", "--log-level", "--chat-template", "--use-default-chat-template",
            "--temp", "--top-p", "--top-k", "--min-p", "--max-tokens", "--chat-template-args", "--decode-concurrency",
            "--prompt-concurrency", "--prefill-step-size", "--prompt-cache-size", "--prompt-cache-bytes", "--kv-bits",
            "--kv-group-size", "--quantized-kv-start", "--pipeline", "--help"]
        var s = ServerSettings(modelID: "m/x")
        s.draftModel = "m/d"; s.chatTemplatePath = "/t"; s.chatTemplateArgs = "{}"; s.adapterPath = "/a"
        s.trustRemoteCode = true; s.minP = 0.1; s.kvBits = 8
        let flags = s.arguments(supported: real).filter { $0.hasPrefix("--") }
        XCTAssertFalse(flags.contains("--max-kv-size"))
        XCTAssertTrue(flags.contains("--kv-bits"))
        XCTAssertEqual(Set(flags).subtracting(real), [])
        // Probed runs also pass --allowed-origins explicitly, hence the + 1.
        XCTAssertEqual(flags.count, s.arguments().filter { $0.hasPrefix("--") }.count + 1, "nothing we emit is dropped")
    }

    func testPartialSettingsFileKeepsStoredValuesAndDefaults() {
        let json = #"{"app":{"idleUnloadMinutes":7,"lastModelID":"a/b"},"perModel":{"a/b":{"modelID":"a/b","contextLength":4096}}}"#
        let p = SettingsStore.decodeLeniently(Data(json.utf8))
        XCTAssertEqual(p.app.idleUnloadMinutes, 7)
        XCTAssertEqual(p.app.lastModelID, "a/b")
        XCTAssertTrue(p.app.onDemandLoading)
        XCTAssertEqual(p.perModel["a/b"]?.contextLength, 4096)
        XCTAssertEqual(p.perModel["a/b"]?.port, 8080)
    }

    func testPortOverrideForProxy() {
        let s = ServerSettings(modelID: "m/x")
        XCTAssertEqual(s.arguments(portOverride: 8081)[s.arguments(portOverride: 8081).firstIndex(of: "--port")! + 1], "8081")
    }

    func testPromptCacheBytes() {
        var s = ServerSettings(modelID: "m/x")
        s.promptCacheGB = 8
        let args = s.arguments()
        XCTAssertEqual(args[args.firstIndex(of: "--prompt-cache-bytes")! + 1], "8589934592")
        s.promptCacheEnabled = false
        XCTAssertFalse(s.arguments().contains("--prompt-cache-bytes"))
    }

    func testFlagProbe() {
        let help = "usage: mlx_lm.server [-h] [--model MODEL] [--host HOST]\n  --prompt-cache-bytes PROMPT_CACHE_BYTES\n  --chat-template-args CHAT_TEMPLATE_ARGS"
        let flags = FlagProbe.parse(helpText: help)
        XCTAssertTrue(flags.contains("--prompt-cache-bytes"))
        XCTAssertTrue(flags.contains("--chat-template-args"))
        XCTAssertFalse(flags.contains("--max-kv-size"))
    }

    func testCommandPreviewQuotesJSON() {
        var s = ServerSettings(modelID: "m/x")
        s.chatTemplateArgs = #"{"enable_thinking":false}"#
        XCTAssertTrue(s.commandPreview().contains(#"'{"enable_thinking":false}'"#))
    }

    func testStorePersistsPerModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: dir)
        let store = SettingsStore(paths: paths)
        var s = ServerSettings(modelID: "m/x")
        s.contextLength = 65_536
        store.save(s)
        var app = store.app
        app.idleUnloadMinutes = 7
        store.app = app
        let reloaded = SettingsStore(paths: paths)
        XCTAssertEqual(reloaded.settings(for: "m/x").contextLength, 65_536)
        XCTAssertEqual(reloaded.app.idleUnloadMinutes, 7)
        XCTAssertEqual(reloaded.settings(for: "other").contextLength, 32_768)
    }

    func testProfiles() {
        var a = AppSettings()
        a.apply(profile: .saver)
        XCTAssertEqual(a.idleUnloadMinutes, 5)
        a.apply(profile: .performance)
        XCTAssertEqual(a.idleUnloadMinutes, 0)
    }
}

final class MemoryPolicyTests: XCTestCase {
    func testKernelLevelMapping() {
        XCTAssertEqual(MemoryMonitor.pressure(fromKernelLevel: 1), .normal)
        XCTAssertEqual(MemoryMonitor.pressure(fromKernelLevel: 2), .warning)
        XCTAssertEqual(MemoryMonitor.pressure(fromKernelLevel: 4), .critical)
    }

    func testEscalation() {
        let s = AppSettings()
        XCTAssertEqual(MemoryPolicy.actions(level: .normal, swapBytes: 0, settings: s), [])
        XCTAssertEqual(MemoryPolicy.actions(level: .warning, swapBytes: 0, settings: s), [.trimPromptCache(toPercent: 50)])
        XCTAssertEqual(MemoryPolicy.actions(level: .high, swapBytes: 0, settings: s),
                       [.trimPromptCache(toPercent: 50), .capContext(tokens: 16_384)])
        let swap = UInt64(3 * 1_073_741_824)
        XCTAssertTrue(MemoryPolicy.actions(level: .critical, swapBytes: swap, settings: s).contains(.unloadModel))
        XCTAssertFalse(MemoryPolicy.actions(level: .critical, swapBytes: 0, settings: s).contains(.unloadModel))
    }

    func testHighIsWarningWithSwap() {
        XCTAssertEqual(MemoryPolicy.level(system: .warning, swapBytes: 1_000_000_000), .high)
        XCTAssertEqual(MemoryPolicy.level(system: .warning, swapBytes: 1_000), .warning)
    }

    func testDisabledRulesAreSkipped() {
        var s = AppSettings()
        s.trimCacheOnWarning = false
        XCTAssertEqual(MemoryPolicy.actions(level: .warning, swapBytes: 0, settings: s), [])
    }
}
