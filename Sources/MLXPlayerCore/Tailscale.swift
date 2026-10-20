import Foundation

/// What the Tailscale app on this Mac says about itself, so the endpoint can be shared over the user's tailnet.
public struct TailscaleInfo: Equatable, Sendable {
    public var connected: Bool
    /// MagicDNS name without the trailing dot, e.g. `macbook.tail1234.ts.net`. Empty when MagicDNS is off.
    public var dnsName: String
    public var ipv4: String

    /// The address other devices on the tailnet should use.
    public var host: String { dnsName.isEmpty ? ipv4 : dnsName }
}

public enum Tailscale {
    /// The host name used in settings for "listen for tailnet devices only".
    public static let hostSetting = "tailscale"

    static let appCLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// Path of the CLI: the one inside the app, or a `tailscale` binary from Homebrew.
    public static func cliPath() -> String? {
        let fm = FileManager.default
        for p in [appCLI, "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"] where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    public static var isInstalled: Bool { cliPath() != nil }

    /// Reads `tailscale status --json`. Nil when Tailscale is not installed or gives no usable answer.
    public static func status() -> TailscaleInfo? {
        guard let cli = cliPath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(data)
    }

    public static func parse(_ data: Data) -> TailscaleInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let me = root["Self"] as? [String: Any]
        let ips = (root["TailscaleIPs"] as? [String]) ?? (me?["TailscaleIPs"] as? [String]) ?? []
        guard let v4 = ips.first(where: { !$0.contains(":") }) else { return nil }
        var name = (me?["DNSName"] as? String) ?? ""
        if name.hasSuffix(".") { name.removeLast() }
        return TailscaleInfo(connected: (root["BackendState"] as? String) == "Running", dnsName: name, ipv4: v4)
    }

    /// Tailnet devices come from 100.64.0.0/10 (carrier-grade NAT space). `address` is an IPv4 in host byte order.
    public static func isTailnetPeer(_ address: UInt32) -> Bool { address & 0xFFC0_0000 == 0x6440_0000 }
}
