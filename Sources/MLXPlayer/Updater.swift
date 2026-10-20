import SwiftUI
import AppKit
import MLXPlayerCore

/// Updates the app from the repo's main branch: check GitHub, build the new commit, verify it,
/// swap it in after quitting, and roll back if the new version doesn't start.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable { case idle, checking, working(String), failed(String) }

    var phase: Phase = .idle
    var status: UpdateStatus?
    var lastChecked: Date?
    var notice: String?
    var log: [String] = []
    let build: BuildInfo
    private let paths: AppPaths
    private var nextAutoCheck = Date()
    /// Set by AppModel: stop the model server before the app quits.
    var beforeQuit: () async -> Void = {}

    init(paths: AppPaths) {
        self.paths = paths
        let info = Bundle.main.infoDictionary ?? [:]
        build = BuildInfo(commit: info["MLXCommit"] as? String,
                          repo: info["MLXRepo"] as? String ?? "kalahroudi/mlxplayer",
                          branch: info["MLXBranch"] as? String ?? "main",
                          version: info["CFBundleShortVersionString"] as? String ?? "0.1.0")
    }

    var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") && build.commit != nil }
    var busy: Bool { if case .checking = phase { return true }; if case .working = phase { return true }; return false }
    var available: UpdateInfo? { if case .available(let i)? = status { return i }; return nil }
    private var markerURL: URL { paths.root.appendingPathComponent("update-ok") }

    // MARK: Launch bookkeeping

    /// Tells a pending swap script that this version started fine, and surfaces a rollback if one happened.
    func confirmLaunch() {
        // Leftovers of a finished update.
        for name in ["staging", "swap.sh", "swap.log"] { try? FileManager.default.removeItem(at: paths.root.appendingPathComponent(name)) }
        let failed = URL(fileURLWithPath: markerURL.path + ".failed")
        if let text = try? String(contentsOf: failed, encoding: .utf8) {
            notice = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: failed)
        }
        // Lets scripts and tests drive an update without clicking: MLX_UPDATE_NOW=1 open "MLX Player.app"
        if ProcessInfo.processInfo.environment["MLX_UPDATE_NOW"] == "1" {
            Task { await check(); await install() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            try? Data().write(to: markerURL)
        }
    }

    // MARK: Check

    /// Once a day at most, quietly. Called from the app's existing timer, so there is no extra polling.
    func autoCheckIfDue(enabled: Bool) {
        guard enabled, isBundled, !busy, Date() >= nextAutoCheck else { return }
        nextAutoCheck = Date().addingTimeInterval(24 * 3600)
        Task { await check(silent: true) }
    }

    func check(silent: Bool = false) async {
        guard !busy else { return }
        guard build.cleanCommit != nil else {
            status = .notComparable("This is a development build.")
            return
        }
        phase = .checking
        do {
            status = try await UpdateChecker().check(build)
            lastChecked = Date()
            phase = .idle
        } catch {
            nextAutoCheck = Date().addingTimeInterval(3600)
            phase = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: Install

    func install() async {
        guard let info = available, !busy else { return }
        log = []
        do {
            try preflight()
            phase = .working("Getting the source")
            let src = paths.root.appendingPathComponent("source", isDirectory: true)
            let head = try await fetchSource(into: src, sha: info.sha)

            phase = .working("Building. This takes a few minutes")
            let staging = paths.root.appendingPathComponent("staging", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try await run("/usr/bin/nice", ["-n", "10", "/bin/bash", "scripts/bundle.sh", build.version], cwd: src,
                          env: ["DIST_DIR": staging.path], failure: { .buildFailed($0) })

            phase = .working("Checking the new build")
            let staged = staging.appendingPathComponent("MLX Player.app")
            try await verify(staged, expect: head)

            phase = .working("Restarting")
            try startSwap(new: staged)
            await beforeQuit()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
            log.append("✗ \(error.localizedDescription)")
        }
    }

    private func preflight() throws {
        guard isBundled else { throw UpdateError.notBundled }
        let dest = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path), fm.isWritableFile(atPath: dest.path) else {
            throw UpdateError.notWritable(dest.path)
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/git") else { throw UpdateError.missingTool("git") }
        guard fm.isExecutableFile(atPath: "/usr/bin/xcrun") else { throw UpdateError.missingTool("Swift") }
    }

    private func fetchSource(into src: URL, sha: String) async throws -> String {
        let git = "/usr/bin/git"
        let url = "https://github.com/\(build.repo).git"
        let fm = FileManager.default
        if !fm.fileExists(atPath: src.appendingPathComponent(".git").path) {
            try? fm.removeItem(at: src)
            try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await run(git, ["clone", "--depth", "1", "--branch", build.branch, "--single-branch", url, src.path],
                          cwd: nil, failure: { .buildFailed($0) })
        } else {
            try await run(git, ["remote", "set-url", "origin", url], cwd: src, failure: { .buildFailed($0) })
            try await run(git, ["fetch", "--depth", "1", "origin", build.branch], cwd: src, failure: { .buildFailed($0) })
            try await run(git, ["reset", "--hard", "FETCH_HEAD"], cwd: src, failure: { .buildFailed($0) })
            try await run(git, ["clean", "-fd"], cwd: src, failure: { .buildFailed($0) })
        }
        final class Box: @unchecked Sendable { var out = "" }
        let box = Box()
        _ = try await runCommand(URL(fileURLWithPath: git), ["rev-parse", "HEAD"], environment: toolEnvironment(),
                                 workingDirectory: src) { box.out += $0 }
        let head = box.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if head != sha { log.append("main moved on; building \(head.prefix(7)) instead of \(sha.prefix(7)).") }
        return head
    }

    private func verify(_ app: URL, expect commit: String) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.verifyFailed("The app wasn't produced.") }
        let exe = app.appendingPathComponent("Contents/MacOS/MLXPlayer").path
        guard fm.isExecutableFile(atPath: exe),
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/mlxplayer-mcp").path) else {
            throw UpdateError.verifyFailed("The app is missing files.")
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], cwd: nil,
                      failure: { .verifyFailed("Signature is invalid. \($0)") })
        // It must start and report the commit we meant to build.
        final class Box: @unchecked Sendable { var out = "" }
        let box = Box()
        let code = try? await runCommand(URL(fileURLWithPath: exe), ["--self-test"], environment: toolEnvironment(), timeout: 20) { box.out += $0 }
        guard code == 0, box.out.contains(commit) else {
            throw UpdateError.verifyFailed("It didn't start correctly.")
        }
    }

    private func startSwap(new: URL) throws {
        let script = paths.root.appendingPathComponent("swap.sh")
        try UpdateSwap.script.write(to: script, atomically: true, encoding: .utf8)
        let dest = Bundle.main.bundleURL
        let backup = dest.deletingLastPathComponent().appendingPathComponent("MLX Player.previous.app")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/bash", script.path, String(ProcessInfo.processInfo.processIdentifier), new.path, dest.path,
                       backup.path, markerURL.path, "40"]
        let logURL = paths.root.appendingPathComponent("swap.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: logURL)
        p.standardError = p.standardOutput
        try p.run()
    }

    private func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env.removeValue(forKey: "DIST_DIR")
        return env
    }

    /// Runs a tool, collecting its output into the visible log.
    private func run(_ exe: String, _ args: [String], cwd: URL?, env: [String: String] = [:],
                     failure: (String) -> UpdateError) async throws {
        var environment = toolEnvironment()
        for (k, v) in env { environment[k] = v }
        final class Tail: @unchecked Sendable { var lines: [String] = [] }
        let tail = Tail()
        let box = self
        do {
            try await runCommand(URL(fileURLWithPath: exe), args, environment: environment, workingDirectory: cwd) { line in
                tail.lines.append(line)
                if tail.lines.count > 8 { tail.lines.removeFirst() }
                Task { @MainActor in
                    box.log.append(line)
                    if box.log.count > 300 { box.log.removeFirst(box.log.count - 300) }
                }
            }
        } catch {
            throw failure(tail.lines.suffix(4).joined(separator: " "))
        }
    }
}
