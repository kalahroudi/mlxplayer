// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-neutral logic: hardware, advisor, settings, proxy, installer, usage.
    .target(name: "MLXPlayerCore"),
    // Stdio MCP server so agents (Claude Code, Cursor, ...) can manage models.
    .executableTarget(name: "mlxplayer-mcp", dependencies: ["MLXPlayerCore"]),
    .testTarget(name: "MLXPlayerCoreTests", dependencies: ["MLXPlayerCore"], exclude: ["Fixtures/fake_backend.py"]),
]
var products: [Product] = [
    .library(name: "MLXPlayerCore", targets: ["MLXPlayerCore"]),
    .executable(name: "mlxplayer-mcp", targets: ["mlxplayer-mcp"]),
]

var dependencies: [Package.Dependency] = []

#if os(macOS)
// Chat screen: OpenAI-compatible streaming client and Markdown rendering, both widely used.
dependencies += [
    .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
]
targets.append(.executableTarget(name: "MLXPlayer", dependencies: [
    "MLXPlayerCore",
    .product(name: "OpenAI", package: "OpenAI"),
    .product(name: "MarkdownUI", package: "swift-markdown-ui"),
]))
products.append(.executable(name: "MLXPlayer", targets: ["MLXPlayer"]))
#endif

let package = Package(
    name: "MLXPlayer",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
