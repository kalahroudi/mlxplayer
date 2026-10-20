import Foundation

/// Small in-memory cache with a time limit and a size cap. Thread safe.
/// Entries expire after `ttl`; the oldest are dropped past `capacity`. `removeAll()` is the invalidation hook.
public final class ResponseCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry { let value: Value; let stored: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(ttl: TimeInterval, capacity: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.capacity = capacity
        self.now = now
    }

    public func value(for key: String) -> Value? {
        lock.withLock {
            guard let e = entries[key] else { return nil }
            if now().timeIntervalSince(e.stored) > ttl { entries[key] = nil; return nil }
            return e.value
        }
    }

    public func store(_ value: Value, for key: String) {
        lock.withLock {
            entries[key] = Entry(value: value, stored: now())
            if entries.count > capacity {
                for (k, _) in entries.sorted(by: { $0.value.stored < $1.value.stored }).prefix(entries.count - capacity) {
                    entries[k] = nil
                }
            }
        }
    }

    public func removeAll() { lock.withLock { entries.removeAll() } }
    public var count: Int { lock.withLock { entries.count } }
}
