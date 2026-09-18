import Foundation
import SlateSyncDomain
import XCTest
@testable import SlateSyncUI

final class AppLocalizationTests: XCTestCase {
    func testCatalogPreservesEveryPlaceholderAndHasEnglishCopy() throws {
        let placeholder = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ value: String) -> [String] {
            let ns = value as NSString
            return placeholder.matches(in: value, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        XCTAssertGreaterThan(L10n.translations.count, 900)
        for (key, translation) in L10n.translations {
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(placeholders(key), placeholders(translation), key)
            // A language's own name remains recognizable in either interface.
            if key != "简体中文" {
                XCTAssertFalse(translation.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }, key)
            }
        }
    }

    func testCountsAndProviderNamesRespectPresentationBoundaries() {
        XCTAssertEqual(L10n.tr("{0} 个任务", ["1"], language: .english), "1 task")
        XCTAssertEqual(L10n.tr("{0} 个任务", ["2"], language: .english), "2 tasks")
        let custom = ProviderSummary(id: "custom", label: "项目库", configured: false, type: .custom)
        XCTAssertEqual(L10n.providerLabel(custom, language: .english), "项目库")
        let builtin = ProviderSummary(id: "openai", label: "OpenAI 官方 API", configured: false, type: .builtin)
        XCTAssertEqual(L10n.providerLabel(builtin, language: .english), "Official OpenAI API")
    }

    func testInterpolationPreservesUserTextAndAllowsEnglishReordering() {
        let userText = "中文项目 {1} %@ 100%"
        XCTAssertEqual(L10n.tr("归档“{0}”", [userText], language: .english), "Archive “\(userText)”")
        XCTAssertEqual(L10n.tr("归档“{0}”", [userText], language: .simplifiedChinese), "归档“\(userText)”")
        XCTAssertEqual(L10n.tr("正在复核第 {0} 页的 {1} 个冲突或查漏候选", ["3", "2"], language: .english),
                       "Reviewing 2 conflicts or missing-record candidates on page 3")
    }

    func testDomainDiagnosticsTranslateAtPresentationWithoutChangingStoredError() {
        let error = SlateSyncError(code: "MODEL_TIMEOUT", message: "模型请求超时")
        XCTAssertEqual(L10n.message(error.message, language: .english), "The model request timed out.")
        XCTAssertEqual(error.message, "模型请求超时")
        XCTAssertEqual(L10n.message("第 1/2 页识别失败：模型请求超时", language: .english),
                       "Recognition failed on page 1/2: The model request timed out.")
        XCTAssertEqual(L10n.message("中文项目 {1} %@", language: .english), "中文项目 {1} %@")
        XCTAssertEqual(L10n.message("Project 演示", language: .english), "Project 演示")
    }

    func testDiagnosticMatchingDoesNotReuseGeneralUITemplates() {
        for key in L10n.productMessagePatternKeys {
            XCTAssertNotNil(L10n.translations[key], "Dynamic product message is missing English copy: \(key)")
        }
        XCTAssertEqual(
            L10n.message("归档“中文项目”", language: .english),
            "归档“中文项目”",
            "A diagnostic renderer must not infer a generic UI action template."
        )
        XCTAssertEqual(
            L10n.message("CSV 文件超过 20 MB 上限", language: .english),
            "The CSV file exceeds the 20 MB limit."
        )
    }

    func testLanguagePreferenceIsSharedPersistedAndRestartScoped() throws {
        let suite = "SlateSync.localization.tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.selected(in: preferences), .simplifiedChinese)
        // The former help-only flag must not silently change the whole app.
        preferences.set(true, forKey: "helpEnglish")
        XCTAssertEqual(AppLanguage.selected(in: preferences), .simplifiedChinese)
        let currentLanguage = L10n.language
        AppLanguage.save(.english, in: preferences)
        XCTAssertEqual(AppLanguage.selected(in: try XCTUnwrap(UserDefaults(suiteName: suite))), .english)
        XCTAssertEqual(preferences.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(L10n.language, currentLanguage, "Saving must not replace the current editing session's language.")
        AppLanguage.save(.simplifiedChinese, in: preferences)
        XCTAssertEqual(preferences.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    }

    @MainActor
    func testHelpUsesAppLanguageAndSearchesBothLanguages() throws {
        let help = HelpModel(language: .english)
        let chapter = try XCTUnwrap(help.sections.first)
        XCTAssertEqual(help.title(chapter), chapter.englishTitle)
        XCTAssertFalse(help.paragraphs(chapter).isEmpty)
        help.query = "配置"
        XCTAssertFalse(help.results.isEmpty)
        help.query = "Provider"
        XCTAssertFalse(help.results.isEmpty)
        let chineseHelp = HelpModel(language: .simplifiedChinese)
        XCTAssertEqual(chineseHelp.title(chapter), chapter.title)
    }
}
