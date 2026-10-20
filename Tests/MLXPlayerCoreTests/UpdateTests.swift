import XCTest
@testable import MLXPlayerCore

final class UpdateTests: XCTestCase {
    func testBuildInfoCleansDirtyCommit() {
        XCTAssertEqual(BuildInfo(commit: "abc123-dirty").cleanCommit, "abc123")
        XCTAssertTrue(BuildInfo(commit: "abc123-dirty").isDirty)
        XCTAssertNil(BuildInfo(commit: "unknown").cleanCommit)
        XCTAssertEqual(BuildInfo(commit: "0123456789abcdef").shortCommit, "0123456")
    }

    func testAheadMeansAvailableWithSummaries() throws {
        let json = #"{"status":"ahead","ahead_by":2,"commits":[{"sha":"a","commit":{"message":"First\n\nbody"}},{"sha":"b","commit":{"message":"Second"}}]}"#
        let s = try UpdateChecker.decide(compareJSON: Data(json.utf8), head: "b")
        guard case .available(let info) = s else { return XCTFail("\(s)") }
        XCTAssertEqual(info.aheadBy, 2)
        XCTAssertEqual(info.summaries, ["First", "Second"])
        XCTAssertEqual(info.sha, "b")
    }

    func testIdenticalAndBehindAreUpToDate() throws {
        for st in ["identical", "behind"] {
            let s = try UpdateChecker.decide(compareJSON: Data(#"{"status":"\#(st)","ahead_by":0}"#.utf8), head: "x")
            XCTAssertEqual(s, .upToDate)
        }
    }

    func testDivergedIsNotOffered() throws {
        let s = try UpdateChecker.decide(compareJSON: Data(#"{"status":"diverged","ahead_by":3}"#.utf8), head: "x")
        guard case .notComparable = s else { return XCTFail("\(s)") }
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try UpdateChecker.decide(compareJSON: Data("nope".utf8), head: "x"))
    }

    // MARK: swap script

    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Fake "app" folders and a fake `open` that writes the OK marker only for bundles containing a `good` file.
    func runSwap(newIsGood: Bool, timeout: Int = 2) throws -> (status: Int32, dest: URL, marker: URL) {
        let fm = FileManager.default
        let new = dir.appendingPathComponent("new.app"), dest = dir.appendingPathComponent("MLX Player.app")
        let bak = dir.appendingPathComponent("old.app"), marker = dir.appendingPathComponent("update-ok")
        for d in [new, dest] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try "old".write(to: dest.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try "new".write(to: new.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        if newIsGood { fm.createFile(atPath: new.appendingPathComponent("good").path, contents: Data()) }
        let open = dir.appendingPathComponent("fake_open.sh")
        try """
        #!/bin/sh
        if [ -f "$1/good" ]; then touch "\(marker.path)"; fi
        """.write(to: open, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        let swap = dir.appendingPathComponent("swap.sh")
        try UpdateSwap.script.write(to: swap, atomically: true, encoding: .utf8)

        // A process that is already gone, so the script doesn't wait.
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [swap.path, String(gone.processIdentifier), new.path, dest.path, bak.path, marker.path, String(timeout), open.path]
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, dest, marker)
    }

    func testSwapKeepsNewVersionWhenItReportsIn() throws {
        let r = try runSwap(newIsGood: true)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try String(contentsOf: r.dest.appendingPathComponent("version")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.app").path), "backup removed")
    }

    func testSwapRollsBackWhenNewVersionNeverReportsIn() throws {
        let r = try runSwap(newIsGood: false)
        XCTAssertEqual(r.status, 2)
        XCTAssertEqual(try String(contentsOf: r.dest.appendingPathComponent("version")), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.marker.path + ".failed"))
    }
}

final class ReleaseUpdateTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("v1.0.0", than: "0.9.9"))
        XCTAssertTrue(Version.isNewer("0.10.0", than: "0.9.0"), "numeric, not alphabetic")
        XCTAssertTrue(Version.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(Version.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "1.0.0-rc.1"), "final beats release candidate")
        XCTAssertFalse(Version.isNewer("1.0.0-rc.1", than: "1.0.0"))
        XCTAssertTrue(Version.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"))
        XCTAssertFalse(Version.isNewer("junk", than: "0.1.0"))
        XCTAssertFalse(Version.isNewer("0.2.0", than: "junk"))
    }

    private let releaseJSON = """
    {"tag_name":"v0.2.0","draft":false,"prerelease":false,
     "body":"## What's new\\n- Overview screen\\n- Benchmark button\\n",
     "assets":[
       {"name":"MLX-Player-0.2.0.dmg","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/MLX-Player-0.2.0.dmg"},
       {"name":"SHA256SUMS","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/SHA256SUMS"}]}
    """

    func testParseRelease() throws {
        let r = try XCTUnwrap(UpdateChecker.parseRelease(Data(releaseJSON.utf8)))
        XCTAssertEqual(r.tag, "v0.2.0"); XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.dmgName, "MLX-Player-0.2.0.dmg")
        XCTAssertEqual(r.checksumsURL?.lastPathComponent, "SHA256SUMS")
        XCTAssertEqual(r.notes, ["What's new", "Overview screen", "Benchmark button"])
    }

    func testReleaseWithoutDmgOrAsDraftIsIgnored() {
        XCTAssertNil(UpdateChecker.parseRelease(Data(#"{"tag_name":"v1","assets":[{"name":"src.zip","browser_download_url":"https://x/y"}]}"#.utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(Data(releaseJSON.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true").utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(Data("nope".utf8)))
    }

    func testChecksumLookup() {
        let sums = "ABCDEF0123  MLX-Player-0.2.0.dmg\n9999  *other.dmg\n"
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "MLX-Player-0.2.0.dmg"), "abcdef0123")
        XCTAssertEqual(UpdateChecker.checksum(in: sums, for: "other.dmg"), "9999")
        XCTAssertNil(UpdateChecker.checksum(in: sums, for: "missing.dmg"))
    }
}
