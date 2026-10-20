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
