import XCTest
@testable import MLXPlayerCore

final class AgentsTests: XCTestCase {
    private func temp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    func testJSONInstallKeepsOtherKeysAndRemoves() throws {
        let url = temp("mcp.json")
        try #"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.write(to: url, atomically: true, encoding: .utf8)
        try AgentIntegrations.jsonInstall(at: url, command: "/a/mlxplayer-mcp")
        XCTAssertEqual(AgentIntegrations.jsonCommand(at: url), "/a/mlxplayer-mcp")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertNotNil((root["mcpServers"] as? [String: Any])?["other"])
        try AgentIntegrations.jsonRemove(at: url)
        XCTAssertNil(AgentIntegrations.jsonCommand(at: url))
    }

    func testJSONInstallRefusesNonObject() throws {
        let url = temp("mcp.json")
        try "[1]".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentIntegrations.jsonInstall(at: url, command: "/a"))
    }

    func testClaudeCodeFindsProjectScopedEntries() throws {
        let url = temp(".claude.json")
        try #"{"projects":{"/p":{"mcpServers":{"mlxplayer":{"command":"/old"}}}}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIntegrations.claudeCodeCommands(at: url), ["/old"])
    }

    func testCodexCommandParsesSection() throws {
        let url = temp("config.toml")
        try "[mcp_servers.other]\ncommand = \"/x\"\n[mcp_servers.mlxplayer]\ncommand = \"/m y\"\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIntegrations.codexCommand(at: url), "/m y")
    }
}
