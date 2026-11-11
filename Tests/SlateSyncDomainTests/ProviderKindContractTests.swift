import SlateSyncDomain
import XCTest

/// Freeze persisted vendor IDs at the Codable boundary, including built-in lookup.
final class ProviderKindContractTests: XCTestCase {
    func testProviderKindJSONRoundTripKeepsLegacyIDs() throws {
        let cases: [(ProviderKind, String)] = [
            (.openAI, "openai"), (.openRouter, "openrouter"), (.tokenPlan, "tokenplan"),
            (.dashScope, "dashscope"), (.openAICompatible, "openai-compatible"),
        ]
        XCTAssertEqual(ProviderKind.allCases, cases.map(\.0))
        // Literal IDs are independent expectations, not values derived from the enum under test.
        for (kind, id) in cases {
            let data = Data("\"\(id)\"".utf8)
            XCTAssertEqual(kind.rawValue, id)
            XCTAssertEqual(try JSONEncoder().encode(kind), data)
            XCTAssertEqual(try JSONDecoder().decode(ProviderKind.self, from: data), kind)
            XCTAssertEqual(ProviderKind(id: id), kind)
        }
        for id in ["openai-compatible:00000000-0000-4000-8000-000000000001",
                   "01234567-89ab-cdef-0123-456789abcdef", "gemini"] {
            XCTAssertNil(ProviderKind(id: id))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderKind.self, from: Data("\"gemini\"".utf8)))
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
