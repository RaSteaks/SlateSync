import CryptoKit
import Foundation
import Observation

public struct HelpStep: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let detail: String
    public let englishTitle: String
    public let englishDetail: String

    public init(
        id: String,
        title: String,
        detail: String,
        englishTitle: String,
        englishDetail: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.englishTitle = englishTitle
        self.englishDetail = englishDetail
    }
}

public struct HelpTip: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let text: String
    public let englishText: String

    public init(id: String, text: String, englishText: String) {
        self.id = id
        self.text = text
        self.englishText = englishText
    }
}

public struct HelpFAQ: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let question: String
    public let answer: String
    public let englishQuestion: String
    public let englishAnswer: String

    public init(
        id: String,
        question: String,
        answer: String,
        englishQuestion: String,
        englishAnswer: String
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.englishQuestion = englishQuestion
        self.englishAnswer = englishAnswer
    }
}

public struct HelpExternalLink: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let englishTitle: String
    public let url: String

    public init(id: String, title: String, englishTitle: String, url: String) {
        self.id = id
        self.title = title
        self.englishTitle = englishTitle
        self.url = url
    }
}

/// Stable, allow-listed actions are resolved by HelpView and cannot execute
/// arbitrary routes or code supplied by the bundled JSON resource.
public enum HelpActionID: String, Hashable, Sendable, Codable {
    case openProjectLibrary
    case openProviderSettings
    case configureOpenRouter
    case openRecognitionSettings
    case openOCRSettings
    case openVisionOCR
    case openPaddleOCR
    case openProjectSettings
    case enterCurrentTask
    case openCurrentTaskCSV
    case openLogs
}

public struct HelpSection: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let symbol: String
    /// Legacy fields remain part of the resource contract so an older help
    /// bundle can still render while the structured fields are introduced.
    public let body: String
    public let englishTitle: String
    public let englishBody: String
    public let paragraphs: [String]
    public let englishParagraphs: [String]
    public let steps: [HelpStep]
    public let tips: [HelpTip]
    public let faqs: [HelpFAQ]
    public let actions: [HelpActionID]
    public let externalLinks: [HelpExternalLink]

    public init(
        id: String,
        title: String,
        symbol: String,
        body: String,
        englishTitle: String,
        englishBody: String,
        paragraphs: [String] = [],
        englishParagraphs: [String] = [],
        steps: [HelpStep] = [],
        tips: [HelpTip] = [],
        faqs: [HelpFAQ] = [],
        actions: [HelpActionID] = [],
        externalLinks: [HelpExternalLink] = []
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.body = body
        self.englishTitle = englishTitle
        self.englishBody = englishBody
        self.paragraphs = paragraphs
        self.englishParagraphs = englishParagraphs
        self.steps = steps
        self.tips = tips
        self.faqs = faqs
        self.actions = actions
        self.externalLinks = externalLinks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, symbol, body, englishTitle, englishBody
        case paragraphs, englishParagraphs, steps, tips, faqs, actions, externalLinks
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        symbol = try values.decode(String.self, forKey: .symbol)
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        englishTitle = try values.decodeIfPresent(String.self, forKey: .englishTitle) ?? title
        englishBody = try values.decodeIfPresent(String.self, forKey: .englishBody) ?? body
        paragraphs = try values.decodeIfPresent([String].self, forKey: .paragraphs) ?? []
        englishParagraphs = try values.decodeIfPresent([String].self, forKey: .englishParagraphs) ?? []
        steps = try values.decodeIfPresent([HelpStep].self, forKey: .steps) ?? []
        tips = try values.decodeIfPresent([HelpTip].self, forKey: .tips) ?? []
        faqs = try values.decodeIfPresent([HelpFAQ].self, forKey: .faqs) ?? []
        let rawActions = try values.decodeIfPresent([String].self, forKey: .actions) ?? []
        actions = rawActions.compactMap(HelpActionID.init(rawValue:))
        externalLinks = try values.decodeIfPresent([HelpExternalLink].self, forKey: .externalLinks) ?? []
    }

    public var searchableText: [String] {
        var values = [title, englishTitle, body, englishBody]
        values.append(contentsOf: paragraphs)
        values.append(contentsOf: englishParagraphs)
        values.append(contentsOf: steps.flatMap { [$0.title, $0.detail, $0.englishTitle, $0.englishDetail] })
        values.append(contentsOf: tips.flatMap { [$0.text, $0.englishText] })
        values.append(contentsOf: faqs.flatMap { [$0.question, $0.answer, $0.englishQuestion, $0.englishAnswer] })
        values.append(contentsOf: externalLinks.flatMap { [$0.title, $0.englishTitle, $0.url] })
        return values
    }
}

/// Versioned bundle-local bilingual help. The digest covers the exact bytes
/// installed with the app; searching and switching language never use network.
@MainActor @Observable
public final class HelpModel {
    public var query = ""
    public var selection: String? = "quick-start" {
        didSet {
            // Keep the former single settings chapter ID usable for callers
            // that persisted a Help selection before the chapter split.
            if selection == "settings" { selection = "providers" }
        }
    }
    // Help shares the launch language with menus and every other app surface.
    public var english: Bool
    public let sections: [HelpSection]
    public let contentSHA256: String
    public let resourceError: String?

    public init(language: AppLanguage = L10n.language) {
        english = language == .english
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

    public func canonicalSectionID(_ id: String?) -> String? {
        guard let id else { return nil }
        return id == "settings" ? "providers" : id
    }

    public func title(_ section: HelpSection) -> String { english ? section.englishTitle : section.title }

    public func body(_ section: HelpSection) -> String {
        english ? section.englishBody : section.body
    }

    public func paragraphs(_ section: HelpSection) -> [String] {
        let values = english ? section.englishParagraphs : section.paragraphs
        return values.isEmpty ? [body(section)] : values
    }

    public func stepTitle(_ step: HelpStep) -> String { english ? step.englishTitle : step.title }
    public func stepDetail(_ step: HelpStep) -> String { english ? step.englishDetail : step.detail }
    public func tipText(_ tip: HelpTip) -> String { english ? tip.englishText : tip.text }
    public func faqQuestion(_ faq: HelpFAQ) -> String { english ? faq.englishQuestion : faq.question }
    public func faqAnswer(_ faq: HelpFAQ) -> String { english ? faq.englishAnswer : faq.answer }
    public func linkTitle(_ link: HelpExternalLink) -> String { english ? link.englishTitle : link.title }

    public var results: [HelpSection] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return sections }
        return sections.filter { $0.searchableText.contains { $0.localizedCaseInsensitiveContains(cleaned) } }
    }
}
