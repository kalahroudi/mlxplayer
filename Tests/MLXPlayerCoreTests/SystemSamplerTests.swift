import XCTest
@testable import MLXPlayerCore

final class SystemSamplerTests: XCTestCase {
    func testBusyFraction() {
        // user 30, system 20, idle 50, nice 0 -> 50% busy
        XCTAssertEqual(CPUMath.busy(from: [0, 0, 0, 0], to: [30, 20, 50, 0]), 0.5, accuracy: 0.001)
        XCTAssertEqual(CPUMath.busy(from: [10, 10, 10, 10], to: [10, 10, 10, 10]), 0)
    }

    func testBusyHandlesCounterWrap() {
        let near = UInt32.max - 5
        XCTAssertEqual(CPUMath.busy(from: [near, 0, 0, 0], to: [4, 0, 10, 0]), 0.5, accuracy: 0.001)
    }

    func testSegmentsCarveModelOutOfWiredFirst() {
        var m = MemoryBreakdown()
        m.total = 64; m.wired = 20; m.apps = 10; m.compressed = 2; m.cached = 12; m.free = 20
        let s = m.segments(modelBytes: 25)
        XCTAssertEqual(s.model, 25)
        XCTAssertEqual(s.wired, 0)
        XCTAssertEqual(s.apps, 5)
        XCTAssertEqual(s.model + s.wired + s.apps + s.compressed, m.used)
    }

    func testSegmentsNeverExceedUsed() {
        var m = MemoryBreakdown()
        m.wired = 5; m.apps = 5
        XCTAssertEqual(m.segments(modelBytes: 999).model, 10)
    }

    func testParseGPU() {
        let r = SystemSampler.parseGPU(["Device Utilization %": 37, "In use system memory": 4_294_967_296])
        XCTAssertEqual(r.utilization ?? 0, 0.37, accuracy: 0.001)
        XCTAssertEqual(r.memoryBytes, 4_294_967_296)
        XCTAssertNil(SystemSampler.parseGPU([:]).utilization)
    }

    func testLiveSampleIsSane() {
        let sampler = SystemSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let s = sampler.sample()
        XCTAssertFalse(s.cpuCores.isEmpty)
        XCTAssertTrue((0...1).contains(s.cpu))
        XCTAssertGreaterThan(s.memory.total, 0)
        XCTAssertLessThanOrEqual(s.memory.free, s.memory.total)
    }
}
