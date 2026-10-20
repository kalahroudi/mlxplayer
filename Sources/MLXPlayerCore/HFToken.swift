import Foundation
#if canImport(Security)
import Security
#endif

/// The user's Hugging Face access token. Stored in the Keychain and cached in memory so
/// every request can read it cheaply. Used for gated models and higher rate limits.
public enum HFToken {
    private static let service = "MLX Player"
    private static let account = "huggingface-token"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: String?
    nonisolated(unsafe) private static var loaded = false

    /// The saved token, or the `HF_TOKEN` environment variable when none is saved.
    public static var current: String? {
        lock.withLock {
            if !loaded { cache = read(); loaded = true }
            if let cache, !cache.isEmpty { return cache }
            let env = ProcessInfo.processInfo.environment["HF_TOKEN"]
            return (env?.isEmpty == false) ? env : nil
        }
    }

    /// True when a token is saved by the app (not just present in the environment).
    public static var isSaved: Bool {
        lock.withLock {
            if !loaded { cache = read(); loaded = true }
            return cache?.isEmpty == false
        }
    }

    public static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if trimmed.isEmpty { remove() ; cache = nil } else { write(trimmed); cache = trimmed }
            loaded = true
        }
    }

    public static func clear() { save("") }

    /// Environment variables that hand the token to child processes.
    public static func environment() -> [String: String] {
        guard let t = current else { return [:] }
        return ["HF_TOKEN": t]
    }

    // MARK: Keychain

    #if canImport(Security)
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ token: String) {
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func remove() { SecItemDelete(query as CFDictionary) }
    #else
    private static func read() -> String? { nil }
    private static func write(_ token: String) {}
    private static func remove() {}
    #endif
}
