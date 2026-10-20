import XCTest
@testable import MLXPlayerCore

final class SupervisorTests: XCTestCase {
    var dir: URL!
    var paths: AppPaths!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = AppPaths(root: dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    static var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake_backend.py").path
    }

    /// A stand-in for mlx_lm.server. `body` runs before the fake backend starts listening.
    func fakeServer(before: String = "") throws -> String {
        let url = dir.appendingPathComponent("fake_server.sh")
        let script = """
        #!/bin/sh
        \(before)
        while [ "$1" != "--port" ]; do shift; done
        exec /usr/bin/python3 -I "\(Self.fixture)" "$2"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func supervisor() -> ServerSupervisor {
        ServerSupervisor(paths: paths, logs: LogBuffer()) { _ in }
    }

    func freePort() -> Int { TCP.firstFreePort(from: 20_000 + Int.random(in: 0..<20_000))! }

    func testStartRunsStopFreesPortAndPidFile() async throws {
        let sup = supervisor(), port = freePort()
        try await sup.start(settings: ServerSettings(modelID: "m/x"), port: port, supportedFlags: nil, customExecutable: try fakeServer())
        let state = await sup.state
        XCTAssertEqual(state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.serverPidFile.path))
        let pid = await sup.processID
        await sup.stop()
        let after = await sup.state
        XCTAssertEqual(after, .stopped)
        XCTAssertFalse(ProcessTree.isAlive(pid ?? 0))
        XCTAssertTrue(TCP.isPortFree(port))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serverPidFile.path))
    }

    /// The app mirrors these callbacks in order; the last one must always match the supervisor's own state.
    func testStateCallbacksEndWhereTheSupervisorIs() async throws {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var states: [ServerState] = []
            func add(_ s: ServerState) { lock.lock(); states.append(s); lock.unlock() } }
        let seen = Seen()
        let sup = ServerSupervisor(paths: paths, logs: LogBuffer()) { seen.add($0) }
        try await sup.start(settings: ServerSettings(modelID: "m/x"), port: freePort(), supportedFlags: nil, customExecutable: try fakeServer())
        XCTAssertEqual(seen.states.last, .running)
        XCTAssertTrue(seen.states.first.map { if case .starting = $0 { return true } else { return false } } ?? false)
        await sup.stop()
        XCTAssertEqual(seen.states.last, .stopped)
        let final = await sup.state
        XCTAssertEqual(final, .stopped)
    }

    func testStopDuringLoadCancelsTheStart() async throws {
        let sup = supervisor(), port = freePort()
        let exe = try fakeServer(before: "sleep 30")
        let starting = Task { try await sup.start(settings: ServerSettings(modelID: "m/x"), port: port, supportedFlags: nil, customExecutable: exe) }
        try await Task.sleep(nanoseconds: 800_000_000)
        await sup.stop()
        do { try await starting.value; XCTFail("start should have been cancelled") }
        catch { XCTAssertEqual(error as? ServerError, .cancelled) }
        let state = await sup.state
        XCTAssertEqual(state, .stopped)
        let pid = await sup.processID
        XCTAssertNil(pid)
    }

    func testSecondStartReplacesTheFirstWithoutOrphans() async throws {
        let sup = supervisor()
        let slow = try fakeServer(before: "sleep 30")
        let first = Task { try await sup.start(settings: ServerSettings(modelID: "m/a"), port: freePort(), supportedFlags: nil, customExecutable: slow) }
        try await Task.sleep(nanoseconds: 800_000_000)
        let port = freePort()
        try await sup.start(settings: ServerSettings(modelID: "m/b"), port: port, supportedFlags: nil, customExecutable: try fakeServer())
        _ = try? await first.value
        let state = await sup.state
        XCTAssertEqual(state, .running)
        let active = await sup.activeSettings
        XCTAssertEqual(active?.modelID, "m/b")
        await sup.stop()
    }

    func testCrashWhileLoadingReportsExitAndOutOfMemory() async throws {
        let sup = supervisor()
        do {
            try await sup.start(settings: ServerSettings(modelID: "m/x"), port: freePort(), supportedFlags: nil,
                                customExecutable: try fakeServer(before: "exit 3"))
            XCTFail()
        } catch { XCTAssertEqual(error as? ServerError, .exited(3)) }

        do {
            try await sup.start(settings: ServerSettings(modelID: "m/x"), port: freePort(), supportedFlags: nil,
                                customExecutable: try fakeServer(before: "echo 'RuntimeError: [metal::malloc] Insufficient Memory' >&2; sleep 0.3; exit 1"))
            XCTFail()
        } catch { XCTAssertEqual(error as? ServerError, .outOfMemory) }
        let state = await sup.state
        if case .failed = state {} else { XCTFail("expected failed, got \(state)") }
    }

    func testBusyPortIsReportedBeforeLaunching() async throws {
        let l = TCPListener(host: "127.0.0.1", port: 0)
        try l.start { TCP.close($0) }
        defer { l.stop() }
        let sup = supervisor()
        do {
            try await sup.start(settings: ServerSettings(modelID: "m/x"), port: l.port, supportedFlags: nil, customExecutable: try fakeServer())
            XCTFail()
        } catch { XCTAssertEqual(error as? ServerError, .portBusy(l.port)) }
    }

    func testReapOrphanKillsOnlyTheRecordedProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]
        try p.run()
        let start = ProcessTree.startTime(of: p.processIdentifier)!
        // Wrong start time: a reused pid. Must be left alone.
        PIDRecord.write(PIDRecord(pid: p.processIdentifier, startTime: start - 1000), to: paths.serverPidFile)
        XCTAssertNil(PIDRecord.reapOrphan(at: paths.serverPidFile))
        XCTAssertTrue(p.isRunning)
        PIDRecord.write(PIDRecord(pid: p.processIdentifier, startTime: start), to: paths.serverPidFile)
        XCTAssertEqual(PIDRecord.reapOrphan(at: paths.serverPidFile), p.processIdentifier)
        p.waitUntilExit()
        XCTAssertFalse(p.isRunning)
    }

    func testDescendantsAreKilledWithTheParent() throws {
        let p = ManagedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 60 & sleep 60 & wait"], environment: [:]) { _ in }
        try p.start()
        Thread.sleep(forTimeInterval: 0.5)
        let kids = ProcessTree.descendants(of: p.processIdentifier)
        XCTAssertGreaterThanOrEqual(kids.count, 2)
        p.killNow()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(kids.allSatisfy { !ProcessTree.isAlive($0) })
    }
}
