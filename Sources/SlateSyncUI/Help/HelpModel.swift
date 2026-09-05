import CryptoKit
import Foundation
import Observation

public struct HelpSection: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let symbol: String
    public let body: String
    public let englishTitle: String
    public let englishBody: String
}

/// Versioned bundle-local bilingual help. The digest covers the exact bytes
/// installed with the app; searching and switching language never use network.
@MainActor @Observable
public final class HelpModel {
    public var query = ""
    public var selection: String? = "quick-start"
    public var english = false
    public let sections: [HelpSection]
    public let contentSHA256: String
    public let resourceError: String?

    public init() {
        do {
            guard let url = Bundle.module.url(forResource: "help-sections", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let data = try Data(contentsOf: url)
            sections = try JSONDecoder().decode([HelpSection].self, from: data)
            contentSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            resourceError = nil
        } catch {
            sections = []
            contentSHA256 = ""
            resourceError = "本地帮助资源无法读取，请重新安装 SlateSync。"
        }
    }

    public func title(_ section: HelpSection) -> String { english ? section.englishTitle : section.title }
    public func body(_ section: HelpSection) -> String { english ? section.englishBody : section.body }

    public var results: [HelpSection] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return sections }
        return sections.filter {
            [$0.title, $0.body, $0.englishTitle, $0.englishBody].contains { $0.localizedCaseInsensitiveContains(cleaned) }
        }
    }
}
