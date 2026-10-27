// swift-tools-version: 6.2
import PackageDescription

// An offline development tool, not a sixth application business module or a
// bundled executable. It reuses the exact Media/Workflow implementations.
let package = Package(
    name: "SlateSyncEvaluation",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "SlateSync", path: "../..")],
    targets: [.executableTarget(name: "SlateSyncEvaluation", dependencies: [
        .product(name: "SlateSyncDomain", package: "SlateSync"),
        .product(name: "SlateSyncMedia", package: "SlateSync"),
        .product(name: "SlateSyncWorkflow", package: "SlateSync"),
    ])],
    swiftLanguageModes: [.v6]
)
