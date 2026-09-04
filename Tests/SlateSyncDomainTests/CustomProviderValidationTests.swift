import XCTest
@testable import SlateSyncDomain

final class CustomProviderValidationTests: XCTestCase {
    func testNormalizeCanonicalizesAndFiltersProviderFields() throws {
        let provider = CustomProviderConfiguration(
            id: "openai-compatible:00000000-0000-4000-8000-0000000000AA",
            name: "  Gateway  ",
            label: "Gateway",
            baseUrl: "https://Gateway.example:443/a/../v1///",
            transport: .responses,
            jsonMode: .prompt,
            imageDetail: .low,
            manualModelIds: ["model-a", "model-a", "bad model", "model/b"],
            revision: 4,
            capabilityCache: [
                "model-a": CustomProviderCapabilityVerification(
                    status: .verified,
                    revision: 4,
                    checkedAt: "2026-09-04T00:00:00Z",
                    transport: .responses,
                    capabilitySource: "probe",
                    message: "Bearer hidden-token sk-provider-secret"
                ),
                "stale-model": CustomProviderCapabilityVerification(
                    status: .pending,
                    revision: 4,
                    message: "pending"
                ),
                "old-model": CustomProviderCapabilityVerification(
                    status: .failed,
                    revision: 3,
                    message: "old"
                ),
            ]
        )

        let normalized = try CustomProviderValidator.normalize(provider)

        XCTAssertEqual(normalized.id, "openai-compatible:00000000-0000-4000-8000-0000000000aa")
        XCTAssertEqual(normalized.name, "Gateway")
        XCTAssertEqual(normalized.label, "Gateway")
        XCTAssertEqual(normalized.baseUrl, "https://gateway.example/v1")
        XCTAssertEqual(normalized.manualModelIds, ["model-a", "model/b"])
        XCTAssertEqual(normalized.capabilityCache?.keys.sorted(), ["model-a"])
        let message = try XCTUnwrap(normalized.capabilityCache?["model-a"]?.message)
        XCTAssertFalse(message.contains("hidden-token"))
        XCTAssertFalse(message.contains("sk-provider-secret"))
    }

    func testNormalizeCanonicalizesPercentEncodedDotSegmentsLikeJavaScript() throws {
        let provider = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Gateway",
            baseUrl: "https://gateway.example/a/.%2E/b///"
        )

        let normalized = try CustomProviderValidator.normalize(provider)

        // WHATWG URL normalization recognizes mixed-case percent-encoded dot
        // segments without decoding unrelated path bytes such as `%2f`.
        XCTAssertEqual(normalized.baseUrl, "https://gateway.example/b")
    }

    func testNormalizeCanonicalizesWHATWGUnicodeIPv4AndBackslashHosts() throws {
        let cases = [
            (#"https://éxample.com/a"#, "https://xn--xample-9ua.com/a"),
            (#"https://0x7f000001/a"#, "https://127.0.0.1/a"),
            (#"https:\example.com\a\b"#, "https://example.com/a/b"),
            (#"https://éxample.com:08080/a"#, "https://xn--xample-9ua.com:8080/a"),
            (#"https://example.com:/a"#, "https://example.com/a"),
            (#"https://127.0.0.1./a"#, "https://127.0.0.1/a"),
            (#"https://[0:0:0:0:0:0:0:1]/a"#, "https://[::1]/a"),
            (#"https://[0:0:0:0:0:ffff:c000:280]/a"#, "https://[::ffff:c000:280]/a"),
        ]

        for (baseURL, expected) in cases {
            let provider = CustomProviderConfiguration(
                id: "openai-compatible",
                name: "Gateway",
                baseUrl: baseURL
            )

            XCTAssertEqual(try CustomProviderValidator.normalize(provider).baseUrl, expected, baseURL)
        }

        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: "openai-compatible",
                    name: "Gateway",
                    baseUrl: "https://example.com:65536/a"
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: "openai-compatible",
                    name: "Gateway",
                    baseUrl: "https://1..2/a"
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: "openai-compatible",
                    name: "Gateway",
                    baseUrl: "https://example.com%2F/a"
                )
            )
        )
    }

    func testNormalizeRejectsUnsafeIdentityAndBaseURL() {
        let base = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Gateway",
            baseUrl: "https://gateway.example/v1"
        )

        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: "openai-compatible:not-a-uuid",
                    name: base.name,
                    baseUrl: base.baseUrl
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: base.id,
                    name: base.name,
                    baseUrl: "https://gateway.example/v1?"
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: base.id,
                    name: base.name,
                    baseUrl: "https://user:password@gateway.example/v1"
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: base.id,
                    name: "\u{0001}",
                    baseUrl: base.baseUrl
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: base.id,
                    name: base.name,
                    baseUrl: "https://[fe80::1%25en0]/v1"
                )
            )
        )
        XCTAssertThrowsError(
            try CustomProviderValidator.normalize(
                CustomProviderConfiguration(
                    id: "OPENAI-COMPATIBLE:00000000-0000-4000-8000-000000000001",
                    name: base.name,
                    baseUrl: base.baseUrl
                )
            )
        )
    }

    func testEmptyUserInfoIsStrippedAndRequestIDIsGeneratedCanonically() throws {
        let request = CustomProviderConfigRequest(
            name: "Gateway",
            baseUrl: "https://@Gateway.example/v1"
        )

        let normalized = try CustomProviderValidator.normalizeRequest(request)

        XCTAssertEqual(normalized.baseUrl, "https://gateway.example/v1")
        XCTAssertTrue(normalized.id.hasPrefix(CustomProviderValidator.idPrefix))
        XCTAssertEqual(normalized.id, normalized.id.lowercased())
        XCTAssertNotNil(normalized.id.dropFirst(CustomProviderValidator.idPrefix.count).range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ))
    }

    func testSanitizeDropsMalformedAndDuplicateRecords() {
        let valid = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Gateway",
            baseUrl: "https://gateway.example/v1"
        )
        let duplicateName = CustomProviderConfiguration(
            id: "openai-compatible:00000000-0000-4000-8000-000000000002",
            name: " gateway ",
            baseUrl: "https://other.example/v1"
        )
        let invalid = CustomProviderConfiguration(
            id: "openai-compatible:invalid",
            name: "Invalid",
            baseUrl: "https://invalid.example/v1"
        )

        let sanitized = CustomProviderValidator.sanitize([valid, duplicateName, invalid])

        XCTAssertEqual(sanitized.map(\.id), ["openai-compatible"])
    }

    func testLegacyDecoderNormalizesAliasesEnumsAndRevisionScopedCache() throws {
        let data = Data(
            #"{"id":"openai-compatible:00000000-0000-4000-8000-000000000004","label":"Legacy Gateway","baseUrl":"","url":"https://GATEWAY.example/v1///","transport":" RESPONSES ","jsonMode":"JSON_OBJECT","imageDetail":"unsupported","revision":"4","capabilityCache":{"model-a":{"status":"verified","revision":"4","message":"Bearer secret"},"stale":{"status":"pending","revision":4}},"verification":{"ignored":{"status":"verified","revision":4}}}"#.utf8
        )

        let provider = try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)

        XCTAssertEqual(provider.baseUrl, "https://gateway.example/v1")
        XCTAssertEqual(provider.transport, .responses)
        XCTAssertEqual(provider.jsonMode, .jsonObject)
        XCTAssertEqual(provider.imageDetail, .high)
        XCTAssertEqual(provider.revision, 4)
        XCTAssertEqual(provider.capabilityCache?.keys.sorted(), ["model-a"])
        XCTAssertEqual(provider.capabilityCache?["model-a"]?.capabilitySource, "probe")
        XCTAssertFalse(provider.capabilityCache?["model-a"]?.message?.contains("secret") ?? true)

        // A present empty name is invalid even when a legacy label is usable;
        // this preserves the JavaScript nullish-vs-empty distinction.
        let emptyName = Data(
            #"{"id":"openai-compatible:00000000-0000-4000-8000-000000000005","name":"","label":"Fallback","baseUrl":"https://gateway.example/v1"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(CustomProviderConfiguration.self, from: emptyName))
    }

    func testCapabilityCacheRequiresAnExplicitMatchingRevisionAndToleratesBadOptionalMetadata() throws {
        let data = Data(
            #"{"id":"openai-compatible:00000000-0000-4000-8000-000000000006","name":"Gateway","baseUrl":"https://gateway.example/v1","revision":1,"capabilityCache":{"missing":{"status":"verified"},"invalid":{"status":"verified","revision":"not-a-number"},"stale":{"status":"verified","revision":2},"malformed":{"status":"verified","revision":1,"checkedAt":42,"message":false,"capabilitySource":{}},"good":{"status":"verified","revision":1,"message":"ok"}}}"#.utf8
        )

        let provider = try JSONDecoder().decode(CustomProviderConfiguration.self, from: data)

        // JavaScript's sanitizer drops unbound cache entries but keeps a
        // valid entry whose optional diagnostic fields have the wrong types.
        XCTAssertEqual(provider.capabilityCache?.keys.sorted(), ["good", "malformed"])
        XCTAssertNil(provider.capabilityCache?["malformed"]?.message)
        XCTAssertEqual(provider.capabilityCache?["malformed"]?.capabilitySource, "probe")
    }
}
