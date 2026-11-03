import XCTest
@testable import MLXPlayerCore

final class LogBufferTests: XCTestCase {
    func testLinesAreKeptOnDiskAndRotate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logbuf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("logs/server.log")
        let buffer = LogBuffer(capacity: 10, file: file, maxFileBytes: 50)
        buffer.append("first line")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first line\n")
        for i in 0..<10 { buffer.append("line number \(i)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
        buffer.clear()
        XCTAssertTrue(buffer.snapshot.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path))
    }
}
