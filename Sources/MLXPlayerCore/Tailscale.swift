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

    // MARK: HTTPS through `tailscale serve`

    public enum ServeState: Equatable, Sendable {
        case off                    // nothing served on 443
        case ours(port: Int)        // 443 forwards to a local port
        case other(String)          // 443 is used for something else; leave it alone
    }

    /// Reads the output of `tailscale serve status --json`.
    public static func parseServe(_ data: Data) -> ServeState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["Web"] as? [String: Any] else { return .off }
        for (key, value) in web where key.hasSuffix(":443") {
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
            let target = ((handlers?["/"] as? [String: Any])?["Proxy"] as? String) ?? ""
            if let url = URL(string: target), let host = url.host, ["127.0.0.1", "localhost"].contains(host), let port = url.port {
                return .ours(port: port)
            }
            return .other(target.isEmpty ? key : target)
        }
        return .off
    }

    public static func serveState() -> ServeState {
        guard let out = run(["serve", "status", "--json"], timeout: 5) else { return .off }
        return parseServe(Data(out.text.utf8))
    }

    /// Publishes `https://<name>.ts.net` and forwards it to the local proxy. Returns nil on success, or what to tell the user.
    public static func enableServe(port: Int) -> String? {
        guard let out = run(["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"], timeout: 8) else { return "Tailscale did not answer." }
        if out.status == 0 { return nil }
        return explain(out.text)
    }

    public static func disableServe() { _ = run(["serve", "--https=443", "off"], timeout: 5) }

    /// Turns the CLI's output into one short line. When HTTPS is not enabled for the tailnet the CLI prints a link to enable it.
    public static func explain(_ output: String) -> String {
        let link = output.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("https://login.tailscale.com") || $0.hasPrefix("https://tailscale.com") }
        if output.localizedCaseInsensitiveContains("not enabled") || output.localizedCaseInsensitiveContains("https") && link != nil {
            return "HTTPS is off for your tailnet." + (link.map { " Enable it once at \($0)" } ?? " Enable HTTPS certificates in the Tailscale admin console.")
        }
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Tailscale could not publish HTTPS."
        return line
    }

    /// Runs the CLI and kills it after `timeout` seconds, because `serve` waits for input when HTTPS is not enabled.
    static func run(_ args: [String], timeout: TimeInterval) -> (status: Int32, text: String)? {
        guard let cli = cliPath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
