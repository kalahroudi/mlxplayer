import Foundation

/// This Mac's address on the local network, so the endpoint can be copied and used from another computer.
public enum LANAddress {
    public struct Candidate: Equatable, Sendable {
        public let interface: String
        public let address: String
        public init(interface: String, address: String) { self.interface = interface; self.address = address }
    }

    /// Picks the address another computer on the network would use: private IPv4 ranges first, Wi-Fi/Ethernet (en*) before
    /// VPN or virtual interfaces, link-local (169.254) last.
    public static func best(_ candidates: [Candidate]) -> String? {
        func rank(_ c: Candidate) -> Int {
            let p = c.address.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return 99 }
            if p[0] == 169 && p[1] == 254 { return 50 }
            let isPrivate = p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            return (isPrivate ? 0 : 10) + (c.interface.hasPrefix("en") ? 0 : 5)
        }
        return candidates.filter { rank($0) < 50 }.min { rank($0) < rank($1) }?.address
            ?? candidates.min { rank($0) < rank($1) }?.address
    }

    /// IPv4 addresses of interfaces that are up, excluding loopback.
    public static func candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [Candidate] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append(Candidate(interface: String(cString: ifa.ifa_name), address: String(cString: host)))
            }
        }
        return found
    }

    public static func current() -> String? { best(candidates()) }
}
