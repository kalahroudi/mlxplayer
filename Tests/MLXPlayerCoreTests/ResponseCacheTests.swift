import XCTest
@testable import MLXPlayerCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let body = Data(#"[{"id":"mlx-community/Qwen3-8B-4bit","downloads":5,"likes":1,"tags":["mlx"]}]"#.utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Link": "<https://huggingface.co/api/models?cursor=next>; rel=\"next\""])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ResponseCacheTests: XCTestCase {
    func testExpiryAndInvalidation() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1000)
        let cache = ResponseCache<Int>(ttl: 60, now: { clock })
        cache.store(7, for: "a")
        XCTAssertEqual(cache.value(for: "a"), 7)
        clock = clock.addingTimeInterval(61)
        XCTAssertNil(cache.value(for: "a"))
        cache.store(1, for: "b"); cache.removeAll()
        XCTAssertNil(cache.value(for: "b"))
    }

    func testCapacityDropsOldest() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 0)
        let cache = ResponseCache<Int>(ttl: 1000, capacity: 2, now: { clock })
        for (i, k) in ["a", "b", "c"].enumerated() { clock = Date(timeIntervalSince1970: Double(i)); cache.store(i, for: k) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "c"), 2)
    }

    func testSearchPagesAreCachedUntilRefreshed() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let client = HuggingFaceClient(session: URLSession(configuration: cfg))
        StubProtocol.requests = 0
        let q = SearchQuery(text: "qwen")

        let first = try await client.searchPage(q)
        _ = try await client.searchPage(q)
        XCTAssertEqual(StubProtocol.requests, 1, "second identical search should come from the cache")
        XCTAssertEqual(first.models.first?.id, "mlx-community/Qwen3-8B-4bit")
        XCTAssertNotNil(first.next)

        _ = try await client.searchPage(SearchQuery(text: "llama"))
        XCTAssertEqual(StubProtocol.requests, 2, "a different query is a different cache entry")

        _ = try await client.searchPage(q, refresh: true)
        XCTAssertEqual(StubProtocol.requests, 3, "refresh bypasses the cache")

        client.invalidateCache()
        _ = try await client.searchPage(q)
        XCTAssertEqual(StubProtocol.requests, 4, "invalidate clears everything")
    }
}
