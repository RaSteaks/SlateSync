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
    func testCapabilityAndSourceBadgesKeepDistinctStates() {
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
    }

    func testTakeMarkMapsEveryTakeStatus() {
        // Every status projects to exactly one of four distinct states; 过条
        // and 保条 are no longer merged into one circled trace.
        XCTAssertEqual(TakeMark(nil).phase, .pending)
        XCTAssertEqual(TakeMark(.passed).phase, .passed)
        XCTAssertEqual(TakeMark(.hold).phase, .hold)
        XCTAssertEqual(TakeMark(.rejected).phase, .rejected)
    }

    func testTakeMarkStatesAreDistinctByShapeAndLabel() {
        // State must read without color: four distinct symbols and labels.
        let phases = TakeMark.Phase.allCases
        XCTAssertEqual(Set(phases.map { TakeMark(phase: $0).symbol }).count, 4)
        XCTAssertEqual(Set(phases.map { TakeMark.label(for: $0) }).count, 4)
        XCTAssertEqual(TakeMark.label(for: .passed), "过条")
        XCTAssertEqual(TakeMark.label(for: .hold), "保条")
        XCTAssertEqual(TakeMark.label(for: .rejected), "废条")
        XCTAssertEqual(TakeMark.label(for: .pending), "待定")
    }

    func testCredentialChipStatesKeepDistinctCopy() {
        XCTAssertEqual(CredentialChip(.configured).title, "已配置")
        XCTAssertEqual(CredentialChip(.missing).title, "缺失")
        XCTAssertEqual(CredentialChip(.needsAuthorization).title, "需要授权")
        XCTAssertEqual(CredentialChip(.readFailed).title, "读取失败")
        let titles = [
            CredentialChip(.configured).title,
            CredentialChip(.missing).title,
            CredentialChip(.needsAuthorization).title,
            CredentialChip(.readFailed).title,
        ]
        XCTAssertEqual(Set(titles).count, 4, "四个凭据状态文案不得互相折叠")
    }
}
