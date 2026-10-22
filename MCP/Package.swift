// swift-tools-version: 6.2
import PackageDescription

// Keep the protocol SDK in this optional executable package. The native app
// and its offline SwiftPM suite retain their existing dependency boundary.
let package = Package(
    name: "SlateSyncMCP",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "slatesync-mcp", targets: ["SlateSyncMCPServer"])],
    dependencies: [
        .package(name: "SlateSync", path: ".."),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.11.0")
    ],
    targets: [
        .target(name: "SlateSyncMCP", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "SlateSyncWorkflow", package: "SlateSync"),
            .product(name: "SlateSyncPersistence", package: "SlateSync"),
            .product(name: "SlateSyncMedia", package: "SlateSync"),
            .product(name: "SlateSyncDomain", package: "SlateSync")
        ]),
        .executableTarget(name: "SlateSyncMCPServer", dependencies: ["SlateSyncMCP"]),
        .testTarget(name: "SlateSyncMCPTests", dependencies: ["SlateSyncMCP"])
    ],
    swiftLanguageModes: [.v6]
)
