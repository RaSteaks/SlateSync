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
    ]),
        // A small offline entry point sharing the production OCR/geometry path.
        // It does not extend the scenario evaluator or perform network calls.
        .executableTarget(name: "SlateSyncRecognitionProbe", dependencies: [
            .product(name: "SlateSyncDomain", package: "SlateSync"),
            .product(name: "SlateSyncMedia", package: "SlateSync"),
            .product(name: "SlateSyncWorkflow", package: "SlateSync"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
