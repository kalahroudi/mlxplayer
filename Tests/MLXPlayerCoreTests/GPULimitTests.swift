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
