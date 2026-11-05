import XCTest
@testable import MLXPlayerCore

final class LibraryTests: XCTestCase {
    private func makeBlobs() throws -> (root: URL, blobs: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        return (root, blobs)
    }

    func testFinishedBlobSymlinkCountsItsRealSizeAndStaleIncompletesAreNotUnfinished() throws {
        let (root, blobs) = try makeBlobs()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("shared")
        try Data(count: 5000).write(to: real)
        try FileManager.default.createSymbolicLink(at: blobs.appendingPathComponent("abc"), withDestinationURL: real)
        try Data(count: 300).write(to: blobs.appendingPathComponent("abc.1111.incomplete"))
        try Data(count: 200).write(to: blobs.appendingPathComponent("abc.2222.incomplete"))

        XCTAssertEqual(ModelLibrary.downloadedBytes(blobs), 5000)
        XCTAssertEqual(ModelLibrary.unfinishedBytes(blobs), 0)
        ModelLibrary.removeStaleIncompletes(blobs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted(), ["abc"])
    }

    func testUnfinishedBlobCountsLargestAttemptOnly() throws {
        let (root, blobs) = try makeBlobs()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 300).write(to: blobs.appendingPathComponent("xyz.1111.incomplete"))
        try Data(count: 200).write(to: blobs.appendingPathComponent("xyz.2222.incomplete"))
        XCTAssertEqual(ModelLibrary.downloadedBytes(blobs), 300)
        XCTAssertGreaterThan(ModelLibrary.unfinishedBytes(blobs), 0)
    }
}
