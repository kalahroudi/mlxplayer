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
