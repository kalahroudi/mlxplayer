import Foundation

/// Minimal HTTP/1.x request head, enough to route and meter OpenAI-style API calls.
public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var version: String
    public var headers: [(name: String, value: String)]

    public static func == (l: HTTPRequestHead, r: HTTPRequestHead) -> Bool {
        l.method == r.method && l.path == r.path && l.version == r.version
            && l.headers.count == r.headers.count
            && zip(l.headers, r.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentLength: Int? { header("Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    public var isChunked: Bool { header("Transfer-Encoding")?.lowercased().contains("chunked") ?? false }
    public var expectsContinue: Bool { header("Expect")?.lowercased().contains("100-continue") ?? false }

    /// Parses the bytes up to (not including) the blank line that ends the head.
    public static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard first.count == 3 else { return nil }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return HTTPRequestHead(method: first[0], path: first[1], version: first[2], headers: headers)
    }

    /// Serialises the head, replacing connection handling so each proxied exchange ends when the backend closes.
    public func serialized(body: Data, forceClose: Bool = true) -> Data {
        var out = "\(method) \(path) \(version)\r\n"
        for (n, v) in headers {
            let lower = n.lowercased()
            if lower == "connection" || lower == "proxy-connection" || lower == "keep-alive"
                || lower == "transfer-encoding" || lower == "content-length" || lower == "expect" { continue }
            out += "\(n): \(v)\r\n"
        }
        if forceClose { out += "Connection: close\r\n" }
        if !body.isEmpty || method == "POST" || method == "PUT" { out += "Content-Length: \(body.count)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }
}

public enum APIMeter {
    /// The "model" field of an OpenAI-style JSON body.
    public static func requestedModel(body: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return obj["model"] as? String
    }

    /// Rough prompt size from the body: about 3.2 characters per token for mixed prose and code.
    public static func estimatePromptTokens(body: Data) -> Int {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body.count / 4 }
        var chars = 0
        if let messages = obj["messages"] as? [[String: Any]] {
            for m in messages {
                if let s = m["content"] as? String { chars += s.count }
                else if let parts = m["content"] as? [[String: Any]] {
                    for p in parts { if let s = p["text"] as? String { chars += s.count } }
                }
            }
        }
        if let s = obj["prompt"] as? String { chars += s.count }
        return Int((Double(chars) / 3.2).rounded(.up))
    }

    public static func isStreaming(body: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["stream"] as? Bool ?? false
    }

    /// Token counts from the tail of a response (JSON body, or the last SSE chunk that carries `usage`).
    public static func usage(inResponseTail data: Data) -> (prompt: Int, completion: Int)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        func last(_ key: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*(\\d+)") else { return nil }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard let m = matches.last, let r = Range(m.range(at: 1), in: text) else { return nil }
            return Int(text[r])
        }
        guard let p = last("prompt_tokens"), let c = last("completion_tokens") else { return nil }
        return (p, c)
    }

    /// Friendly client name from a User-Agent header.
    public static func clientName(userAgent: String?) -> String {
        let ua = (userAgent ?? "").lowercased()
        if ua.isEmpty { return "Unknown" }
        if ua.contains("claude") { return "Claude Code" }
        if ua.contains("cursor") { return "Cursor" }
        if ua.contains("open-webui") || ua.contains("open webui") { return "Open WebUI" }
        if ua.contains("vscode") || ua.contains("continue") { return "VS Code" }
        if ua.contains("zed") { return "Zed" }
        if ua.contains("curl") { return "curl" }
        if ua.contains("openai") { return "OpenAI SDK" }
        if ua.contains("python") || ua.contains("httpx") || ua.contains("requests") { return "Python" }
        if ua.contains("node") || ua.contains("undici") { return "Node" }
        return "Other"
    }

    public static func openAIError(message: String, code: String) -> Data {
        let obj: [String: Any] = ["error": ["message": message, "type": "invalid_request_error", "code": code]]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
