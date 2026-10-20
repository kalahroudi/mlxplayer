// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-neutral logic: hardware, advisor, settings, proxy, installer, usage.
    .target(name: "MLXPlayerCore"),
    // Stdio MCP server so agents (Claude Code, Cursor, ...) can manage models.
    .executableTarget(name: "mlxplayer-mcp", dependencies: ["MLXPlayerCore"]),
    .testTarget(name: "MLXPlayerCoreTests", dependencies: ["MLXPlayerCore"]),
]
var products: [Product] = [
    .library(name: "MLXPlayerCore", targets: ["MLXPlayerCore"]),
    .executable(name: "mlxplayer-mcp", targets: ["mlxplayer-mcp"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "MLXPlayer", dependencies: ["MLXPlayerCore"]))
products.append(.executable(name: "MLXPlayer", targets: ["MLXPlayer"]))
#endif

let package = Package(
    name: "MLXPlayer",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
