import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the app tells local tools (the MCP server) how to reach it.
public struct ControlInfo: Codable, Equatable, Sendable {
    public var port: Int
    public var token: String

    public static func make(port: Int) -> ControlInfo {
        ControlInfo(port: port, token: (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) -> ControlInfo? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ControlInfo.self, from: $0) }
    }
}

/// Loopback JSON API the app exposes so agents can operate it (with the user's approval).
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ method: String, _ path: String, _ body: [String: Any]) async -> (Int, [String: Any])

    private let listener = TCPListener(host: "127.0.0.1", port: 0)
    public let info: ControlInfo
    private let handler: Handler

    public init(handler: @escaping Handler) throws {
        self.handler = handler
        // Port is learned after binding, so build the token first and patch the port in start().
        self.info = ControlInfo(port: 0, token: ControlInfo.make(port: 0).token)
    }

    public private(set) var port = 0

    public func start(writingTo url: URL) throws {
        let token = info.token
        let handler = self.handler
        try listener.start { fd in
            defer { TCP.close(fd) }
            guard let req = HTTPReader.readRequest(fd: fd) else { return }
            func send(_ status: Int, _ obj: [String: Any]) {
                let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                TCP.writeAll(fd, HTTPReader.response(status: status, reason: status == 200 ? "OK" : "Error", body: data))
            }
            guard req.head.header("Authorization") == "Bearer \(token)" else {
                send(401, ["error": "unauthorized"])
                return
            }
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let path = req.head.path.split(separator: "?").first.map(String.init) ?? req.head.path
            let method = req.head.method
            let result = runBlocking { await handler(method, path, body) }
            send(result.0, result.1)
        }
        port = listener.port
        try ControlInfo(port: port, token: token).write(to: url)
    }

    public func stop() { listener.stop() }
}

public enum ControlClientError: Error, LocalizedError {
    case appNotRunning
    case denied(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotRunning: return "MLX Player is not running. Open the app first."
        case .denied(let m): return m
        case .failed(let m): return m
        }
    }
}

public final class ControlClient: @unchecked Sendable {
    private let paths: AppPaths
    private let session: URLSession

    public init(paths: AppPaths, session: URLSession = .shared) {
        self.paths = paths
        self.session = session
    }

    public func call(_ method: String, _ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let info = ControlInfo.read(from: paths.controlFile) else { throw ControlClientError.appNotRunning }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(info.port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 600  // approvals and cold model loads can take a while
        req.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw ControlClientError.appNotRunning }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw ControlClientError.denied(obj["error"] as? String ?? "Denied by the user.") }
        if code != 200 { throw ControlClientError.failed(obj["error"] as? String ?? "Request failed (HTTP \(code)).") }
        return obj
    }
}
