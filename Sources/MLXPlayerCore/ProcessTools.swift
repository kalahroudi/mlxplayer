import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process-tree and memory helpers (macOS). On other platforms they do nothing, so the core still builds.
public enum ProcessTree {
    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// All children, grandchildren and so on.
    public static func descendants(of pid: Int32) -> [Int32] {
        #if canImport(Darwin)
        var out: [Int32] = []
        var queue = [pid]
        while let next = queue.popLast() {
            let count = proc_listchildpids(next, nil, 0)
            guard count > 0 else { continue }
            var buf = [Int32](repeating: 0, count: Int(count) + 8)
            let got = proc_listchildpids(next, &buf, Int32(buf.count * MemoryLayout<Int32>.size))
            for child in buf.prefix(Int(max(got, 0))) where child > 0 && !out.contains(child) {
                out.append(child)
                queue.append(child)
            }
        }
        return out
        #else
        return []
        #endif
    }

    /// Process start time in seconds since 1970, which tells a reused pid from the original process.
    public static func startTime(of pid: Int32) -> Int? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? Int(info.pbi_start_tvsec) : nil
        #else
        return nil
        #endif
    }

    /// Physical footprint of a process plus its children. This is what Activity Monitor calls "Memory"
    /// and, unlike resident size, it includes GPU-wired memory that MLX allocates.
    public static func footprint(of pid: Int32) -> UInt64 {
        #if canImport(Darwin)
        ([pid] + descendants(of: pid)).reduce(0) { $0 + footprintSingle($1) }
        #else
        return 0
        #endif
    }

    #if canImport(Darwin)
    private static func footprintSingle(_ pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }
    #endif
}

/// Remembers the model server's pid so a crashed app can clean up after itself on the next launch.
public struct PIDRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startTime: Int

    public static func write(_ record: PIDRecord, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
    }

    public static func read(_ url: URL) -> PIDRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PIDRecord.self, from: data)
    }

    /// Kills a server left behind by a previous run (crash, force quit). Returns the pid it killed.
    /// The start time must match, so an unrelated process that reused the pid is never touched.
    @discardableResult
    public static func reapOrphan(at url: URL) -> Int32? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let r = read(url), ProcessTree.isAlive(r.pid),
              let started = ProcessTree.startTime(of: r.pid), abs(started - r.startTime) <= 1 else { return nil }
        let children = ProcessTree.descendants(of: r.pid)
        kill(r.pid, SIGTERM)
        for _ in 0..<30 where ProcessTree.isAlive(r.pid) { usleep(100_000) }
        if ProcessTree.isAlive(r.pid) { kill(r.pid, SIGKILL) }
        for c in children where ProcessTree.isAlive(c) { kill(c, SIGKILL) }
        return r.pid
    }
}
