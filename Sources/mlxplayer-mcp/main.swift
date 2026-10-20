import Foundation
import MLXPlayerCore

// Stdio MCP server. Register with:  claude mcp add mlxplayer -- /path/to/mlxplayer-mcp
let server = MCPServer(tools: MCPTools.make(paths: AppPaths()))
let done = DispatchSemaphore(value: 0)
Task {
    await server.serveStdio()
    done.signal()
}
done.wait()
