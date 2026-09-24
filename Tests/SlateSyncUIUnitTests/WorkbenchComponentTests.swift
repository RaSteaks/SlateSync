import SlateSyncDomain
import XCTest

@testable import SlateSyncUI

// Contracts for the 2026-09-14 workbench components: status mapping stays
// total (every TakeStatus projects to exactly one trace), the leader dial
// copy keeps real page numbers, and the credential chip never collapses an
// authorization failure into a missing credential. View conformances make
// the component initializers MainActor-isolated, so the suite runs there.
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
        XCTAssertEqual(TakeMark(nil).phase, .pending)
        XCTAssertEqual(TakeMark(.passed).phase, .circled)
        XCTAssertEqual(TakeMark(.hold).phase, .circled)
        XCTAssertEqual(TakeMark(.rejected).phase, .struck)
    }

    func testLeaderProgressReportsRealPages() {
        let dial = LeaderProgress(completedPages: 2, totalPages: 5)
        XCTAssertEqual(dial.centerLabel, "第 2/5 页")
        XCTAssertEqual(dial.accessibilityValue, "第 2 页,共 5 页")
        // Unknown totals fall back to the named phase, never a fake fraction.
        let phase = LeaderProgress(phaseText: "正在识别第 3 页")
        XCTAssertEqual(phase.centerLabel, "正在识别第 3 页")
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
