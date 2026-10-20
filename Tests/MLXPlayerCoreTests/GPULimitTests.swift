import XCTest
@testable import MLXPlayerCore

final class GPULimitTests: XCTestCase {
    let gb: UInt64 = 1_073_741_824

    func testMaxLeavesFloorForMacOS() {
        XCTAssertEqual(GPULimit.maxMB(totalBytes: 64 * gb), 61_440)
        XCTAssertEqual(GPULimit.maxMB(totalBytes: 2 * gb), 0)
    }

    func testSuggestedIsNinetyPercentButCapped() {
        XCTAssertEqual(GPULimit.suggestedMB(totalBytes: 128 * gb), Int(Double(128 * gb) * 0.9 / 1_048_576))
        XCTAssertEqual(GPULimit.suggestedMB(totalBytes: 8 * gb), 4096)
    }

    func testValidation() throws {
        try GPULimit.validate(0, totalBytes: 32 * gb)
        try GPULimit.validate(24_576, totalBytes: 32 * gb)
        XCTAssertThrowsError(try GPULimit.validate(30_000, totalBytes: 32 * gb))
        XCTAssertThrowsError(try GPULimit.validate(1_000, totalBytes: 32 * gb))
    }

    func testScriptContainsOnlyInteger() {
        XCTAssertEqual(GPULimit.script(mb: 8192),
                       "do shell script \"/usr/sbin/sysctl iogpu.wired_limit_mb=8192\" with administrator privileges")
    }
}

final class HFSearchTests: XCTestCase {
    func testExpandFieldsAreAllowedByTheHub() {
        // From the Hub's own 400 response, 2026-10-20. `usedStorage` is no longer accepted.
        let allowed: Set<String> = ["author", "baseModels", "cardData", "config", "createdAt", "disabled", "downloads",
            "downloadsAllTime", "evalResults", "gated", "inference", "inferenceProviderMapping", "lastModified",
            "library_name", "likes", "mask_token", "model-index", "pipeline_tag", "private", "safetensors", "sha",
            "siblings", "spaces", "tags", "transformersInfo", "trendingScore", "widgetData", "gguf", "resourceGroup", "xetEnabled"]
        for f in HuggingFaceClient.expandFields { XCTAssertTrue(allowed.contains(f), f) }
    }

    func testSearchURLCarriesFilterAndFields() {
        let url = HuggingFaceClient.searchURL(SearchQuery(text: "qwen", limit: 30), base: URL(string: "https://huggingface.co")!)
        let s = url.absoluteString
        XCTAssertTrue(s.contains("filter=mlx")); XCTAssertTrue(s.contains("limit=30")); XCTAssertTrue(s.contains("search=qwen"))
        XCTAssertFalse(s.contains("usedStorage"))
    }

    func testNextLink() {
        let h = "<https://huggingface.co/api/models?cursor=abc>; rel=\"next\", <https://huggingface.co/api/models>; rel=\"prev\""
        XCTAssertEqual(HuggingFaceClient.nextLink(h)?.absoluteString, "https://huggingface.co/api/models?cursor=abc")
        XCTAssertNil(HuggingFaceClient.nextLink(nil))
        XCTAssertNil(HuggingFaceClient.nextLink("<https://x>; rel=\"prev\""))
    }
}

final class ModelFormatTests: XCTestCase {
    func testDetect() {
        XCTAssertEqual(ModelFormat.detect(id: "mlx-community/Qwen3-8B-4bit", tags: []), .mlx)
        XCTAssertEqual(ModelFormat.detect(id: "unsloth/Qwen3-8B-GGUF", tags: ["gguf", "safetensors"]), .gguf)
        XCTAssertEqual(ModelFormat.detect(id: "TheBloke/Llama-2-7B-GPTQ", tags: ["safetensors", "gptq"]), .gptq)
        XCTAssertEqual(ModelFormat.detect(id: "x/Model-AWQ", tags: []), .awq)
        XCTAssertEqual(ModelFormat.detect(id: "onnx-community/Model", tags: ["onnx"]), .onnx)
        XCTAssertEqual(ModelFormat.detect(id: "meta/Llama-3-8B", tags: ["safetensors"]), .safetensors)
        XCTAssertEqual(ModelFormat.detect(id: "someone/m", tags: ["mlx", "gguf"]), .mlx)
    }

    func testOnlyMLXRunsHere() {
        XCTAssertEqual(ModelFormat.allCases.filter(\.runsHere), [.mlx])
    }

    func testSearchURLUsesFormatFilterAndDropsAuthorForOthers() {
        let base = URL(string: "https://huggingface.co")!
        let gguf = HuggingFaceClient.searchURL(SearchQuery(publisher: nil, format: .gguf), base: base).absoluteString
        XCTAssertTrue(gguf.contains("filter=gguf")); XCTAssertFalse(gguf.contains("author="))
        XCTAssertTrue(gguf.contains("pipeline_tag=text-generation"))
        let mlx = HuggingFaceClient.searchURL(SearchQuery(), base: base).absoluteString
        XCTAssertTrue(mlx.contains("filter=mlx")); XCTAssertTrue(mlx.contains("author=mlx-community"))
        XCTAssertTrue(mlx.contains("pipeline_tag=text-generation"))
        // Even if a caller leaves the publisher set, a non-MLX search must not be limited to mlx-community.
        let leaked = HuggingFaceClient.searchURL(SearchQuery(publisher: "mlx-community", format: .gguf), base: base).absoluteString
        XCTAssertFalse(leaked.contains("author="))
    }

    func testFilterAppliesFormat() {
        var f = ModelFilter(); f.format = .gguf
        let models = [ModelMetadata.fromName("mlx-community/Qwen3-8B-4bit"),
                      ModelMetadata(id: "unsloth/Qwen3-8B-GGUF", tags: ["gguf"])]
        XCTAssertEqual(f.apply(models, advisor: nil).map(\.id), ["unsloth/Qwen3-8B-GGUF"])
    }
}

final class GPUPersistTests: XCTestCase {
    func testPlistIsValidAndCarriesValue() throws {
        let xml = GPULimit.daemonPlist(mb: 40960)
        let plist = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, GPULimit.daemonLabel)
        XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist?["ProgramArguments"] as? [String], ["/usr/sbin/sysctl", "iogpu.wired_limit_mb=40960"])
    }

    func testPlistPassesPlutilLint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("x.plist")
        try GPULimit.daemonPlist(mb: 8192).write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-lint", file.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testPersistScriptRoundTripsAndHasNoQuotes() throws {
        let script = GPULimit.persistScript(mb: 24576)
        XCTAssertFalse(script.contains("\""), "a quote would break the AppleScript string")
        XCTAssertFalse(script.contains("\\"))
        // The base64 argument decodes back to the plist.
        let b64 = script.split(separator: " ")[1]
        let decoded = String(data: Data(base64Encoded: String(b64))!, encoding: .utf8)
        XCTAssertEqual(decoded, GPULimit.daemonPlist(mb: 24576))
        XCTAssertTrue(script.contains("launchctl bootstrap system /Library/LaunchDaemons/com.mlxplayer.gpulimit.plist"))
    }

    func testRemoveScriptResetsToDefault() {
        let s = GPULimit.removeScript()
        XCTAssertFalse(s.contains("\""))
        XCTAssertTrue(s.contains("rm -f /Library/LaunchDaemons/com.mlxplayer.gpulimit.plist"))
        XCTAssertTrue(s.hasSuffix("iogpu.wired_limit_mb=0"))
    }
}
