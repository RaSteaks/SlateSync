// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SlateSync",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SlateSyncDomain", targets: ["SlateSyncDomain"]),
        .library(name: "SlateSyncPersistence", targets: ["SlateSyncPersistence"]),
        .library(name: "SlateSyncMedia", targets: ["SlateSyncMedia"]),
        .library(name: "SlateSyncWorkflow", targets: ["SlateSyncWorkflow"]),
        .library(name: "SlateSyncUI", targets: ["SlateSyncUI"]),
    ],
    targets: [
        .target(name: "SlateSyncDomain"),
        .target(name: "SlateSyncPersistence", dependencies: ["SlateSyncDomain"]),
        .target(name: "SlateSyncMedia", dependencies: ["SlateSyncDomain"]),
        .target(
            name: "SlateSyncWorkflow",
            dependencies: ["SlateSyncDomain", "SlateSyncPersistence", "SlateSyncMedia"]
        ),
        .target(
            name: "SlateSyncUI",
            dependencies: [
                "SlateSyncDomain",
                "SlateSyncPersistence",
                "SlateSyncMedia",
                "SlateSyncWorkflow",
            ]
        ),
        .testTarget(
            name: "SlateSyncDomainTests",
            dependencies: ["SlateSyncDomain"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SlateSyncPersistenceTests",
            dependencies: ["SlateSyncDomain", "SlateSyncPersistence"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SlateSyncMediaTests",
            dependencies: ["SlateSyncDomain", "SlateSyncMedia"],
            // Unique SM-06 names keep frozen oracles and offline media fixtures
            // deterministic even when SwiftPM flattens processed resources.
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SlateSyncWorkflowTests",
            dependencies: ["SlateSyncDomain", "SlateSyncPersistence", "SlateSyncWorkflow"],
            // SM-05 byte goldens are copied as resources so tests never depend
            // on the invocation directory or a user's real Resolve exports.
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
