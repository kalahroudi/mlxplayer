import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which build is running, read from the app's Info.plist (written by scripts/bundle.sh).
public struct BuildInfo: Equatable, Sendable {
    public var commit: String?
    public var repo: String
    public var branch: String
    public var version: String

    public init(commit: String?, repo: String = "kalahroudi/mlxplayer", branch: String = "main", version: String = "0") {
        self.commit = commit; self.repo = repo; self.branch = branch; self.version = version
    }

    /// The commit without a "-dirty" marker (the build had uncommitted changes).
    public var cleanCommit: String? {
        guard let c = commit, c != "unknown", !c.isEmpty else { return nil }
        return c.hasSuffix("-dirty") ? String(c.dropLast(6)) : c
    }
    public var isDirty: Bool { commit?.hasSuffix("-dirty") == true }
    public var shortCommit: String { cleanCommit.map { String($0.prefix(7)) } ?? "dev" }
}

public struct UpdateInfo: Equatable, Sendable {
    public var sha: String
    public var aheadBy: Int
    /// First lines of the commit messages that are new, newest last.
    public var summaries: [String]
    public var shortSha: String { String(sha.prefix(7)) }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
    /// This build can't be compared with the branch (local build, or it has commits main doesn't).
    case notComparable(String)
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case network(String)
    case rateLimited
    case badResponse
    case missingTool(String)
    case notBundled
    case notWritable(String)
    case buildFailed(String)
    case verifyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't reach GitHub. \(m)"
        case .rateLimited: return "GitHub is limiting requests. Try again in a few minutes."
        case .badResponse: return "GitHub sent an answer I couldn't read."
        case .missingTool(let t): return "\(t) is needed to build the update. Install the Xcode command line tools."
        case .notBundled: return "Updates work from the installed app, not from a development build."
        case .notWritable(let p): return "No permission to replace \(p). Move the app to a folder you own."
        case .buildFailed(let m): return "The build failed. \(m)"
        case .verifyFailed(let m): return "The new build didn't pass checks, so nothing was replaced. \(m)"
        }
    }
}

/// Asks GitHub whether `branch` has commits this build lacks.
public struct UpdateChecker: Sendable {
    public var session: URLSession
    public var apiBase = "https://api.github.com"

    public init(session: URLSession = .shared) { self.session = session }

    public func check(_ build: BuildInfo) async throws -> UpdateStatus {
        guard let current = build.cleanCommit else {
            return .notComparable("This build has no commit recorded.")
        }
        let head = try await headSHA(repo: build.repo, branch: build.branch)
        if head == current { return .upToDate }
        let (data, code) = try await get("/repos/\(build.repo)/compare/\(current)...\(head)")
        if code == 404 { return .notComparable("This build isn't on \(build.branch) yet.") }
        guard code == 200 else { throw UpdateError.badResponse }
        return try Self.decide(compareJSON: data, head: head)
    }

    func headSHA(repo: String, branch: String) async throws -> String {
        let (data, code) = try await get("/repos/\(repo)/commits/\(branch)")
        guard code == 200 else { throw UpdateError.badResponse }
        guard let sha = Self.parseSHA(data) else { throw UpdateError.badResponse }
        return sha
    }

    static func parseSHA(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String
    }

    /// Pure, so tests can feed it saved responses.
    static func decide(compareJSON data: Data, head: String) throws -> UpdateStatus {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { throw UpdateError.badResponse }
        let ahead = obj["ahead_by"] as? Int ?? 0
        switch status {
        case "identical", "behind": return .upToDate
        case "ahead":
            let commits = obj["commits"] as? [[String: Any]] ?? []
            let lines = commits.compactMap { ($0["commit"] as? [String: Any])?["message"] as? String }
                .map { String($0.split(separator: "\n").first ?? "") }
            return .available(UpdateInfo(sha: head, aheadBy: ahead, summaries: Array(lines.suffix(8))))
        default:
            return .notComparable("This build has changes that aren't on the branch.")
        }
    }

    private func get(_ path: String) async throws -> (Data, Int) {
        guard let url = URL(string: apiBase + path) else { throw UpdateError.badResponse }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MLXPlayer-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 || code == 429 { throw UpdateError.rateLimited }
            return (data, code)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

/// The script that swaps the app bundle after the app quits, and puts the old one back if the new one
/// never reports in. It runs outside the app because the app can't replace itself while running.
public enum UpdateSwap {
    public static let script = """
    #!/bin/bash
    # usage: swap.sh PID NEW_APP DEST_APP BACKUP_APP OK_MARKER TIMEOUT_SECONDS [OPEN_COMMAND]
    PID="$1"; NEW="$2"; DEST="$3"; BAK="$4"; MARK="$5"; TIMEOUT="${6:-30}"; OPEN="${7:-open}"

    # 1. Wait for the old app to quit, then make sure it has.
    for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID"; sleep 0.5; fi

    # 2. Swap, keeping the old bundle until the new one proves itself.
    rm -rf "$BAK"
    if ! mv "$DEST" "$BAK"; then echo "Couldn't move the current app aside." > "$MARK.failed"; $OPEN "$DEST"; exit 1; fi
    if ! mv "$NEW" "$DEST"; then
      mv "$BAK" "$DEST"; echo "Couldn't put the new app in place." > "$MARK.failed"; $OPEN "$DEST"; exit 1
    fi
    rm -f "$MARK" "$MARK.failed"
    $OPEN "$DEST"

    # 3. The new app writes the marker once it is up. No marker: roll back.
    for i in $(seq 1 $((TIMEOUT * 2))); do
      if [ -f "$MARK" ]; then rm -rf "$BAK"; exit 0; fi
      sleep 0.5
    done
    pkill -f "$DEST/Contents/MacOS/" 2>/dev/null; sleep 1
    rm -rf "$DEST"; mv "$BAK" "$DEST"
    echo "The new version didn't start, so the previous one was restored." > "$MARK.failed"
    $OPEN "$DEST"
    exit 2
    """
}
