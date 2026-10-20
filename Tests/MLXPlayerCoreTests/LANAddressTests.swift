import XCTest
@testable import MLXPlayerCore

final class LANAddressTests: XCTestCase {
    typealias C = LANAddress.Candidate

    func testPrefersPrivateWiFiOverVPN() {
        XCTAssertEqual(LANAddress.best([C(interface: "utun4", address: "10.8.0.2"), C(interface: "en0", address: "192.168.1.42")]), "192.168.1.42")
    }

    func testPrefersPrivateOverPublicOnEthernet() {
        XCTAssertEqual(LANAddress.best([C(interface: "en1", address: "203.0.113.9"), C(interface: "en0", address: "10.0.0.5")]), "10.0.0.5")
    }

    func testLinkLocalOnlyWhenNothingElse() {
        XCTAssertEqual(LANAddress.best([C(interface: "en0", address: "169.254.3.4"), C(interface: "en1", address: "172.16.0.9")]), "172.16.0.9")
        XCTAssertEqual(LANAddress.best([C(interface: "en0", address: "169.254.3.4")]), "169.254.3.4")
        XCTAssertNil(LANAddress.best([]))
    }
}

final class TailscaleTests: XCTestCase {
    func testParsesStatus() {
        let json = #"{"BackendState":"Running","TailscaleIPs":["100.82.89.41","fd7a::1"],"Self":{"DNSName":"mac.tail1.ts.net."}}"#
        XCTAssertEqual(Tailscale.parse(Data(json.utf8)), TailscaleInfo(connected: true, dnsName: "mac.tail1.ts.net", ipv4: "100.82.89.41"))
        XCTAssertEqual(Tailscale.parse(Data(json.utf8))?.host, "mac.tail1.ts.net")
    }

    func testStoppedAndNoMagicDNSFallsBackToIP() {
        let json = #"{"BackendState":"Stopped","TailscaleIPs":["100.1.2.3"],"Self":{"DNSName":""}}"#
        let info = Tailscale.parse(Data(json.utf8))
        XCTAssertEqual(info?.connected, false)
        XCTAssertEqual(info?.host, "100.1.2.3")
        XCTAssertNil(Tailscale.parse(Data("{}".utf8)))
    }

    func testTailnetPeerRange() {
        XCTAssertTrue(Tailscale.isTailnetPeer(0x6452_5929))   // 100.82.89.41
        XCTAssertTrue(Tailscale.isTailnetPeer(0x647F_FFFF))   // 100.127.255.255
        XCTAssertFalse(Tailscale.isTailnetPeer(0x6480_0000))  // 100.128.0.0
        XCTAssertFalse(Tailscale.isTailnetPeer(0xC0A8_0096))  // 192.168.0.150
    }
}

final class PeerFilterTests: XCTestCase {
    private func roundTrip(allow: Bool) throws -> Data? {
        let l = TCPListener(host: "127.0.0.1", port: 0)
        l.peerFilter = { _ in allow }
        try l.start { fd in TCP.writeAll(fd, Data("hi".utf8)); TCP.close(fd) }
        defer { l.stop() }
        guard let c = TCP.connect(host: "127.0.0.1", port: l.port) else { return nil }
        defer { TCP.close(c) }
        return TCP.read(c)
    }

    func testFilterDropsRejectedPeers() throws {
        XCTAssertEqual(try roundTrip(allow: true), Data("hi".utf8))
        let rejected = try roundTrip(allow: false)
        XCTAssertTrue(rejected == nil || rejected!.isEmpty)
    }
}

final class TailscaleServeTests: XCTestCase {
    private func state(_ json: String) -> Tailscale.ServeState { Tailscale.parseServe(Data(json.utf8)) }

    func testServeStates() {
        XCTAssertEqual(state("{}"), .off)
        XCTAssertEqual(state(#"{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}"#), .ours(port: 8080))
        XCTAssertEqual(state(#"{"Web":{"mac.ts.net:443":{"Handlers":{"/":{"Proxy":"http://192.168.1.5:3000"}}}}}"#), .other("http://192.168.1.5:3000"))
        XCTAssertEqual(state(#"{"Web":{"mac.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}"#), .off)
    }

    func testExplainsDisabledHTTPS() {
        let out = "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=abc\n"
        XCTAssertEqual(Tailscale.explain(out), "HTTPS is off for your tailnet. Enable it once at https://login.tailscale.com/f/serve?node=abc")
        XCTAssertEqual(Tailscale.explain("some other failure\nmore"), "some other failure")
    }
}
