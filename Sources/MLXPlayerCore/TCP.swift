import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin blocking-socket helpers. Local API traffic is low-volume, so thread-per-connection is plenty
/// and keeps the dependency list empty.
public enum TCP {
    static var streamType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static let sendFlags: Int32 = {
        #if canImport(Glibc)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }()

    static func ignoreSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Reads up to `max` bytes. Returns nil on EOF or error.
    public static func read(_ fd: Int32, max: Int = 65_536) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
        if n <= 0 { return nil }
        return Data(buf[0..<n])
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let n = send(fd, base + offset, data.count - offset, sendFlags)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    public static func connect(host: String, port: Int) -> Int32? {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { return nil }
        ignoreSigPipe(fd)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 { close(fd); return nil }
        return fd
    }

    public static func close(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }
}

/// Accepts TCP connections on a loopback (or any) address and hands each to `handler` on its own thread.
public final class TCPListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private let host: String
    private let requestedPort: Int
    private let lock = NSLock()
    private var stopped = false
    public private(set) var port: Int = 0

    public init(host: String, port: Int) {
        self.host = host
        self.requestedPort = port
    }

    public func start(handler: @escaping @Sendable (Int32) -> Void) throws {
        let s = socket(AF_INET, TCP.streamType, 0)
        guard s >= 0 else { throw ListenerError.socket(errno) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        TCP.ignoreSigPipe(s)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(requestedPort).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { let e = errno; TCP.close(s); throw ListenerError.bind(e) }
        guard listen(s, 128) == 0 else { let e = errno; TCP.close(s); throw ListenerError.listen(e) }

        // Learn the real port when 0 was requested.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &len) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        fd = s

        let thread = Thread { [weak self] in
            while let self, !self.isStopped {
                let client = accept(s, nil, nil)
                if client < 0 { if self.isStopped { break }; continue }
                TCP.ignoreSigPipe(client)
                Thread.detachNewThread { handler(client) }
            }
        }
        thread.name = "tcp-listener-\(port)"
        thread.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    public func stop() {
        lock.withLock { stopped = true }
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            TCP.close(fd)
            fd = -1
        }
    }
}

public enum ListenerError: Error, LocalizedError {
    case socket(Int32), bind(Int32), listen(Int32)

    public var errorDescription: String? {
        switch self {
        case .socket(let e): return "Could not create socket (\(String(cString: strerror(e))))"
        case .bind(let e): return "Could not listen on that port (\(String(cString: strerror(e))))"
        case .listen(let e): return "Listen failed (\(String(cString: strerror(e))))"
        }
    }
}

/// Reads a full HTTP request (head and body) from a socket.
public enum HTTPReader {
    public struct Request {
        public var head: HTTPRequestHead
        public var body: Data
    }

    public static func readRequest(fd: Int32, maxBody: Int = 64 * 1_048_576) -> Request? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            guard let chunk = TCP.read(fd) else { return nil }
            buffer.append(chunk)
            headEnd = buffer.range(of: terminator)
            if buffer.count > 128 * 1024, headEnd == nil { return nil }
        }
        guard let end = headEnd, let head = HTTPRequestHead.parse(buffer[buffer.startIndex..<end.lowerBound]) else { return nil }
        var body = Data(buffer[end.upperBound...])

        if head.expectsContinue { TCP.writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }

        if head.isChunked {
            var decoded = Data()
            var raw = body
            while true {
                // Find chunk size line.
                while raw.range(of: Data("\r\n".utf8)) == nil {
                    guard let more = TCP.read(fd) else { return nil }
                    raw.append(more)
                }
                let lineEnd = raw.range(of: Data("\r\n".utf8))!
                let sizeLine = String(data: raw[raw.startIndex..<lineEnd.lowerBound], encoding: .utf8) ?? ""
                let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? "0"
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                raw.removeSubrange(raw.startIndex..<lineEnd.upperBound)
                if size == 0 { break }
                while raw.count < size + 2 {
                    guard let more = TCP.read(fd) else { return nil }
                    raw.append(more)
                }
                decoded.append(raw.prefix(size))
                raw.removeSubrange(raw.startIndex..<raw.startIndex + size + 2)
                if decoded.count > maxBody { return nil }
            }
            body = decoded
        } else if let length = head.contentLength {
            if length > maxBody { return nil }
            while body.count < length {
                guard let more = TCP.read(fd) else { return nil }
                body.append(more)
            }
            body = body.prefix(length)
        } else {
            body = Data()
        }
        return Request(head: head, body: body)
    }

    public static func response(status: Int, reason: String, contentType: String = "application/json",
                                body: Data, extraHeaders: [String: String] = [:]) -> Data {
        var out = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in extraHeaders { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }
}
