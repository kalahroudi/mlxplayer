import SwiftUI
import AppKit
import MLXPlayerCore
import CryptoKit

/// Updates the app from the repo's main branch: check GitHub, build the new commit, verify it,
/// swap it in after quitting, and roll back if the new version doesn't start.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable { case idle, checking, working(String), failed(String) }

    var phase: Phase = .idle
    var status: UpdateStatus?
    var lastChecked: Date?
    var notice: String?
    var log: [String] = [] { didSet { persist(newLines: Array(log.dropFirst(min(oldValue.count, log.count)))) } }
    /// 0...1 while a download is running, nil when the step has no measurable progress.
    var progress: Double?
    /// Shown once after a restart: what the last update did.
    var lastResult: String?
    /// Set by AppModel to raise a toast.
    var onResult: (_ success: Bool, _ text: String) -> Void = { _, _ in }
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
    private var logURL: URL { paths.root.appendingPathComponent("update.log") }
    private var pendingURL: URL { paths.root.appendingPathComponent("update-pending.json") }

    /// Keeps the log on disk, so what happened is still readable after the app restarted.
    private func persist(newLines: [String]) {
        guard !newLines.isEmpty, let data = (newLines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: logURL) }
    }

    private func beginRun(to target: String) {
        log = []
        try? FileManager.default.removeItem(at: logURL)
        log.append("Update \(build.shortCommit) → \(target) at \(Date().formatted())")
        let info: [String: String] = ["from": build.cleanCommit ?? build.version, "fromVersion": build.version, "to": target]
        try? JSONSerialization.data(withJSONObject: info).write(to: pendingURL)
    }

    /// The previous run's log, for the Updates pane.
    var savedLog: [String] {
        (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
    private var markerURL: URL { paths.root.appendingPathComponent("update-ok") }

    // MARK: Launch bookkeeping

    /// Tells a pending swap script that this version started fine, and surfaces a rollback if one happened.
    func confirmLaunch() {
        // Leftovers of a finished update.
        let fm = FileManager.default
        let swapLog = (try? String(contentsOf: paths.root.appendingPathComponent("swap.log"), encoding: .utf8)) ?? ""
        for name in ["staging", "swap.sh", "swap.log"] { try? fm.removeItem(at: paths.root.appendingPathComponent(name)) }
        let failed = URL(fileURLWithPath: markerURL.path + ".failed")
        let failure = (try? String(contentsOf: failed, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? fm.removeItem(at: failed)
        if let data = try? Data(contentsOf: pendingURL),
           let pending = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            try? fm.removeItem(at: pendingURL)
            let now = build.cleanCommit ?? build.version
            let target = pending["to"] ?? ""
            let arrived = failure == nil && (now.hasPrefix(target) || target.hasPrefix(now) || "v\(build.version)" == target
                                             || (pending["from"] != now && pending["fromVersion"] != build.version))
            if arrived {
                lastResult = "Updated to \(build.version) · \(build.shortCommit)"
                log.append("Started fine: \(build.version) · \(build.shortCommit)")
                DispatchQueue.main.async { [self] in onResult(true, lastResult ?? "Updated") }
            } else {
                let why = failure ?? "The new version didn't replace the old one."
                notice = why
                log.append("✗ \(why)")
                if !swapLog.isEmpty { log.append(contentsOf: swapLog.split(separator: "\n").map(String.init)) }
                DispatchQueue.main.async { [self] in onResult(false, why) }
            }
        } else if let failure {
            notice = failure
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
        if let release = info.release { await installRelease(release); return }
        beginRun(to: info.sha)
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

    /// Prebuilt path: download the disk image, check its hash, unpack, verify, swap. No Xcode tools needed.
    private func installRelease(_ release: ReleaseInfo) async {
        beginRun(to: release.tag)
        let fm = FileManager.default
        let staging = paths.root.appendingPathComponent("staging", isDirectory: true)
        let mount = staging.appendingPathComponent("mnt", isDirectory: true)
        var mounted = false
        do {
            try preflight(needsBuildTools: false)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            phase = .working("Downloading \(release.tag)")
            let dmg = staging.appendingPathComponent(release.dmgName)
            try await download(release.dmgURL, to: dmg)

            phase = .working("Checking the download")
            try await verifyChecksum(of: dmg, release: release)

            phase = .working("Unpacking")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path], cwd: nil,
                          failure: { .verifyFailed("Couldn't open the disk image. \($0)") })
            mounted = true
            let staged = staging.appendingPathComponent("MLX Player.app")
            try await run("/usr/bin/ditto", [mount.appendingPathComponent("MLX Player.app").path, staged.path], cwd: nil,
                          failure: { .verifyFailed("The disk image has no app. \($0)") })
            try await run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"], cwd: nil, failure: { .verifyFailed($0) })
            mounted = false
            try? fm.removeItem(at: dmg)

            phase = .working("Checking the new build")
            try await verify(staged, expect: nil)

            phase = .working("Restarting")
            try startSwap(new: staged)
            await beforeQuit()
            NSApp.terminate(nil)
        } catch {
            if mounted { _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], cwd: nil, failure: { .verifyFailed($0) }) }
            phase = .failed(error.localizedDescription)
            log.append("✗ \(error.localizedDescription)")
        }
    }

    /// Streams the file to disk so the pane can show a real progress bar.
    private func download(_ url: URL, to file: URL) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("The download failed.") }
        let total = resp.expectedContentLength
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close(); progress = nil }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        progress = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress = Double(received) / Double(total) }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        log.append("Downloaded \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)).")
    }

    /// Compares the download with the release's SHA256SUMS. Without a published sum it only warns.
    private func verifyChecksum(of file: URL, release: ReleaseInfo) async throws {
        guard let sumsURL = release.checksumsURL else {
            log.append("This release has no checksum file; relying on the code signature only.")
            return
        }
        let (data, _) = try await URLSession.shared.data(from: sumsURL)
        guard let sums = String(data: data, encoding: .utf8),
              let expected = UpdateChecker.checksum(in: sums, for: release.dmgName) else {
            throw UpdateError.verifyFailed("The checksum file doesn't list \(release.dmgName).")
        }
        let actual = try await Task.detached { () -> String in
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard actual == expected else { throw UpdateError.verifyFailed("The download is damaged (checksum mismatch).") }
        log.append("Checksum matches.")
    }

    private func preflight(needsBuildTools: Bool = true) throws {
        guard isBundled else { throw UpdateError.notBundled }
        let dest = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path), fm.isWritableFile(atPath: dest.path) else {
            throw UpdateError.notWritable(dest.path)
        }
        guard needsBuildTools else { return }
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

    /// `commit` is the commit a source build must report; a release build only has to start and say ok.
    private func verify(_ app: URL, expect commit: String?) async throws {
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
        guard code == 0, commit.map({ box.out.contains($0) }) ?? box.out.hasPrefix("ok") else {
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
