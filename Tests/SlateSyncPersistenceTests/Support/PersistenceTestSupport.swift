import Foundation
import SlateSyncDomain
import XCTest

enum PersistenceTestSupport {
    static func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSync-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func scenarioProfile(fingerprint: String = "fingerprint-v1") -> ScenarioProfile {
        let field = ScenarioFieldProfile(
            label: "字段",
            aliases: [],
            region: [0.1, 0.2, 0.3, 0.4],
            inherit: false,
            required: false
        )
        return ScenarioProfile(
            schemaVersion: 1,
            fingerprintVersion: 1,
            fingerprint: fingerprint,
            label: "测试场记",
            layout: ScenarioLayout(
                pages: [
                    ScenarioPageShape(
                        pageNumber: 1,
                        views: [ScenarioViewShape(width: 1920, height: 1080, orientation: "landscape", blockCount: 2)]
                    ),
                ],
                headerTokens: ["场", "镜"],
                cameraGroups: ["A"],
                columnBands: [0.1, 0.5],
                rowBands: [0.2, 0.8],
                blockCount: 2
            ),
            fields: ScenarioFields(
                cardNumber: field,
                videoCode: field,
                scene: field,
                shot: field,
                take: field,
                takeStatus: field,
                description: field,
                comments: field,
                shotSize: field,
                cameraPosition: field
            ),
            recognition: ScenarioRecognitionConfig(headerTokens: ["场"], promptHints: ["读取场号"]),
            output: ScenarioOutputConfig(resolve: .init())
        )
    }
}

// Keeping the helpers in the test target makes every persistence test use the
// same isolated-directory construction path.
