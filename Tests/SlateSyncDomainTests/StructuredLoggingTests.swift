import XCTest
@testable import SlateSyncDomain

final class StructuredLoggingTests: XCTestCase {
    func testNestedMetadataAndMessageRedactCredentialForms() throws {
        let secret = "sk-native-secret"
        let event = StructuredLogEvent(
            level: .error,
            category: "recognition",
            message: "request failed Authorization: Bearer bearer-secret token=token-secret",
            metadata: [
                "apiKey": .string(secret),
                "requestId": .string("request-123"),
                "records": .array([
                    .object(["access_token": .string("access-secret")]),
                    .string("Bearer nested-bearer"),
                ]),
            ]
        )

        let safe = StructuredLogRedactor.redact(event)
        let encoded = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)

        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("bearer-secret"))
        XCTAssertFalse(encoded.contains("access-secret"))
        XCTAssertTrue(encoded.contains("request-123"))
        XCTAssertTrue(encoded.contains(StructuredLogRedactor.redactedText))
    }

    func testPrivacyClassificationKeepsIdentifiersPrivateAndKnownDataPublic() {
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "api_key"), .redacted)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "Authorization"), .redacted)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "refreshToken"), .redacted)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "client_secret"), .redacted)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "set-cookie"), .redacted)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "taskId"), .private)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "path"), .private)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "recordCount"), .public)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "author"), .public)
        XCTAssertEqual(StructuredLogRedactor.privacy(for: "authorToken"), .redacted)
    }

    func testMessageRedactsOAuthAndClientCredentialLabels() {
        let safe = StructuredLogRedactor.redactText(
            "refreshToken=refresh-secret id_token=id-secret client_secret=client-secret authToken=auth-secret"
        )

        XCTAssertFalse(safe.contains("refresh-secret"))
        XCTAssertFalse(safe.contains("id-secret"))
        XCTAssertFalse(safe.contains("client-secret"))
        XCTAssertFalse(safe.contains("auth-secret"))
        XCTAssertEqual(safe.components(separatedBy: StructuredLogRedactor.redactedText).count, 5)
    }

    func testGoogleCredentialFormIsRedactedAndDeepMetadataIsBounded() throws {
        let googleCredential = "AIza123456789012345678901"
        let safeMessage = StructuredLogRedactor.redactText("credential=\(googleCredential)")
        XCTAssertFalse(safeMessage.contains(googleCredential))
        XCTAssertTrue(safeMessage.contains(StructuredLogRedactor.redactedText))

        var nested: JSONValue = .string("deep-secret")
        for _ in 0..<70 {
            nested = .array([nested])
        }
        let safe = StructuredLogRedactor.redact(nested)
        let encoded = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)

        // Malformed imported diagnostics cannot force unbounded recursion and
        // the sentinel below must not survive the depth cutoff.
        XCTAssertFalse(encoded.contains("deep-secret"))
        XCTAssertTrue(encoded.contains(StructuredLogRedactor.redactedText))
    }
}
