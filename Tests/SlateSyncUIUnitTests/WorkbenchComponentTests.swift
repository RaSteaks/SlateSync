import SlateSyncDomain
import XCTest

@testable import SlateSyncUI

// Contracts for the workbench components: status mapping stays total (every
// TakeStatus projects to exactly one glyph, distinct by shape and label), and
// the credential chip never collapses an authorization failure into a missing
// credential. View conformances make the component initializers
// MainActor-isolated, so the suite runs there.
@MainActor
final class WorkbenchComponentTests: XCTestCase {
    func testProviderBadgesKeepDistinctStates() {
        // Mixed probe outcomes need a warning rather than a verified badge;
        // preset provenance is metadata and leaves provider type unchanged.
        XCTAssertEqual(CapabilityChip.state(verified: 1, failed: 1, pending: 0), .attention)
        XCTAssertEqual(CapabilityChip.state(verified: 0, failed: 1, pending: 0), .failed)
        XCTAssertEqual(CapabilityChip.state(verified: 0, failed: 0, pending: 1), .unverified)
        XCTAssertEqual(CapabilityChip.state(verified: 1, failed: 0, pending: 0), .verified)
        XCTAssertEqual(ProviderSourceBadge.source(for: nil), .builtin)
        let custom = CustomProviderConfiguration(id: "openai-compatible", name: "Test",
            baseUrl: "https://example.com/v1")
        let preset = CustomProviderConfiguration(id: "openai-compatible", name: "Preset",
            baseUrl: "https://example.com/v1", sourcePresetID: "stepfun")
        XCTAssertEqual(ProviderSourceBadge.source(for: custom), .custom)
        XCTAssertEqual(ProviderSourceBadge.source(for: preset), .preset)
        // Keep error states distinct without coupling the test to translated wording.
        let credentialTitles = [CredentialChip(.configured), CredentialChip(.missing),
                                CredentialChip(.needsAuthorization), CredentialChip(.readFailed)].map(\.title)
        XCTAssertEqual(Set(credentialTitles).count, 4, "Credential states must remain distinguishable")
    }

    func testTakeMarkStatesAreDistinctByShapeAndLabel() {
        // State must read without color; literal copy is owned by the localization catalog.
        XCTAssertEqual([TakeMark(nil).phase, TakeMark(.passed).phase, TakeMark(.hold).phase, TakeMark(.rejected).phase],
                       [.pending, .passed, .hold, .rejected])
        let phases = TakeMark.Phase.allCases
        XCTAssertEqual(Set(phases.map { TakeMark(phase: $0).symbol }).count, 4)
        XCTAssertEqual(Set(phases.map { TakeMark.label(for: $0) }).count, 4)
    }
}
