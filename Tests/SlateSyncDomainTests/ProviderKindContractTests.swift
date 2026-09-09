import SlateSyncDomain
import XCTest

/// SM-09 #13: vendor protocol shapes are one enum whose raw values ARE the
/// frozen wire IDs. Business logic branches on cases; string literals may
/// exist only at this Codable/persistence boundary.
final class ProviderKindContractTests: XCTestCase {
    func testProviderKindRawValuesAreFrozenProviderIDs() {
        XCTAssertEqual(
            ProviderKind.allCases,
            [.openAI, .openRouter, .tokenPlan, .dashScope, .openAICompatible]
        )
        XCTAssertEqual(
            ProviderKind.allCases.map(\.rawValue),
            ["openai", "openrouter", "tokenplan", "dashscope", "openai-compatible"]
        )
    }

    func testProviderKindJSONRoundTripKeepsLegacyIDs() throws {
        for kind in ProviderKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(kind.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(ProviderKind.self, from: data), kind)
        }
        // Unknown vendor strings fail closed instead of silently mapping.
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderKind.self, from: Data("\"gemini\"".utf8)))
    }

    func testProviderKindLookupOnlyMatchesBuiltinIDs() {
        XCTAssertEqual(ProviderKind(id: "openai"), .openAI)
        XCTAssertEqual(ProviderKind(id: "openrouter"), .openRouter)
        XCTAssertEqual(ProviderKind(id: "tokenplan"), .tokenPlan)
        XCTAssertEqual(ProviderKind(id: "dashscope"), .dashScope)
        XCTAssertEqual(ProviderKind(id: "openai-compatible"), .openAICompatible)
        // Custom UUID providers keep string IDs and no vendor kind.
        XCTAssertNil(ProviderKind(id: "openai-compatible:00000000-0000-4000-8000-000000000001"))
        XCTAssertNil(ProviderKind(id: "01234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertNil(ProviderKind(id: "gemini"))
    }

    func testProviderOriginRawValuesStayStableForPersistence() throws {
        // The old ProviderKind (builtin/custom) keeps its Codable boundary
        // under the new ProviderOrigin name.
        XCTAssertEqual(ProviderOrigin.builtin.rawValue, "builtin")
        XCTAssertEqual(ProviderOrigin.custom.rawValue, "custom")
        XCTAssertEqual(try JSONDecoder().decode(ProviderOrigin.self, from: Data("\"builtin\"".utf8)), .builtin)
        XCTAssertEqual(try JSONDecoder().decode(ProviderOrigin.self, from: Data("\"custom\"".utf8)), .custom)
    }
}
