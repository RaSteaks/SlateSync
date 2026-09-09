import SlateSyncDomain
import SlateSyncWorkflow
import XCTest

/// SM-09 #13: the registry, catalog, credential names and transport route on
/// `ProviderKind` cases instead of scattered provider string literals.
@MainActor
final class ProviderKindRoutingTests: XCTestCase {
    func testCatalogDefinitionsCarryMatchingKinds() {
        // Catalog order and IDs are frozen; each definition must declare the
        // matching vendor kind.
        XCTAssertEqual(
            ProviderCatalog.definitions.map(\.id),
            ProviderKind.allCases.map(\.rawValue)
        )
        for definition in ProviderCatalog.definitions {
            XCTAssertEqual(definition.kind.rawValue, definition.id, definition.id)
            XCTAssertEqual(ProviderKind(id: definition.id), definition.kind)
        }
    }

    func testCredentialNamesAreFrozenPerKind() async throws {
        let registry = ProviderRegistry()
        let summaries = await registry.providerSummaries()
        let requiredEnv = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.requiredEnv) })
        XCTAssertEqual(requiredEnv["openai"], ["OPENAI_API_KEY"])
        XCTAssertEqual(requiredEnv["openrouter"], ["OPENROUTER_API_KEY"])
        XCTAssertEqual(requiredEnv["tokenplan"], ["TOKENPLAN_API_KEY"])
        XCTAssertEqual(requiredEnv["dashscope"], ["DASHSCOPE_API_KEY"])
        XCTAssertEqual(requiredEnv["openai-compatible"], ["OPENAI_COMPATIBLE_API_KEY"])
    }

    func testDescriptorCarriesVendorKind() async throws {
        let settings = GlobalSettingValues()
        var values = settings
        values[.openAICompatibleBaseUrl] = "https://gateway.example/v1"
        let registry = ProviderRegistry(settings: values)

        for kind in ProviderKind.allCases {
            let descriptor = try await registry.descriptor(providerID: kind.rawValue)
            XCTAssertEqual(descriptor.providerKind, kind, kind.rawValue)
        }

        // The materialized legacy compatible provider keeps its vendor kind;
        // UUID custom providers have none.
        let legacy = CustomProviderConfiguration(
            id: "openai-compatible",
            name: "Legacy Gateway",
            baseUrl: "https://legacy.example/v1"
        )
        let custom = CustomProviderConfiguration(
            id: CustomProviderValidator.idPrefix + "00000000-0000-4000-8000-000000000002",
            name: "LAN Gateway",
            baseUrl: "https://lan.example/v1"
        )
        await registry.replace(settings: values, customProviders: [legacy, custom])
        let legacyDescriptor = try await registry.descriptor(providerID: "openai-compatible")
        XCTAssertEqual(legacyDescriptor.providerKind, .openAICompatible)
        let customDescriptor = try await registry.descriptor(
            providerID: CustomProviderValidator.idPrefix + "00000000-0000-4000-8000-000000000002"
        )
        XCTAssertNil(customDescriptor.providerKind)
    }
}
