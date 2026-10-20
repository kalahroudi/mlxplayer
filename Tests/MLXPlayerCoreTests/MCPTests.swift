import XCTest
@testable import MLXPlayerCore

final class MCPTests: XCTestCase {
    func server() -> MCPServer {
        MCPServer(tools: [MCPTool(name: "echo", description: "d", schema: ["type": "object"]) { args in
            if args["fail"] as? Bool == true { throw ControlClientError.denied("nope") }
            return "hi \(args["name"] ?? "")"
        }])
    }

    func call(_ s: MCPServer, _ json: String) async -> [String: Any]? {
        guard let data = await s.handle(json) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testHandshakeAndTools() async {
        let s = server()
        let initResp = await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        XCTAssertEqual((initResp?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        let note = await call(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(note)
        let list = await call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, 1)
        let ok = await call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"name":"bob"}}}"#)
        let text = (((ok?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]) as? String
        XCTAssertEqual(text, "hi bob")
        let bad = await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"fail":true}}}"#)
        XCTAssertEqual((bad?["result"] as? [String: Any])?["isError"] as? Bool, true)
        let missing = await call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"zzz"}}"#)
        XCTAssertNotNil(missing?["error"])
    }

    func testRealToolsListAndHardware() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let tools = MCPTools.make(paths: paths)
        XCTAssertTrue(tools.map(\.name).contains("recommend_models"))
        let hw = try await tools.first { $0.name == "get_hardware" }!.run([:])
        XCTAssertTrue(hw.contains("model_budget_gb"))
        // With no app running, state-changing tools explain why.
        do { _ = try await tools.first { $0.name == "stop_server" }!.run([:]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not running")) }
    }
}
