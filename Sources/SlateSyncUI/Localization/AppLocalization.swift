import Foundation
import Synchronization
import SlateSyncDomain

/// One launch-scoped language for every window, command and product message.
/// Settings persists the next launch's choice; it never rebuilds live editors.
public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "applicationLanguage"
    public var locale: Locale { Locale(identifier: rawValue) }

    public static func selected(in preferences: UserDefaults) -> Self {
        Self(rawValue: preferences.string(forKey: preferenceKey) ?? "") ?? .simplifiedChinese
    }

    /// Apple's language preference controls native menus and file panels on the
    /// next launch. Use the caller's suite so isolated tests never change real preferences.
    public static func save(_ language: Self, in preferences: UserDefaults) {
        preferences.set(language.rawValue, forKey: preferenceKey)
        preferences.set([language.rawValue], forKey: "AppleLanguages")
    }
}

public enum L10n {
    private static let activeLanguage = Mutex<AppLanguage>(.simplifiedChinese)
    public static var language: AppLanguage { activeLanguage.withLock { $0 } }

    /// Called once by the app composition root, before creating feature models.
    public static func configure(preferences: UserDefaults) {
        let selected = AppLanguage.selected(in: preferences)
        activeLanguage.withLock { $0 = selected }
        AppLanguage.save(selected, in: preferences)
    }

    /// Built-in provider names are product copy; user-created names are data.
    public static func providerLabel(_ provider: ProviderSummary, language: AppLanguage? = nil) -> String {
        provider.type == .builtin ? message(provider.label, language: language) : provider.label
    }

    static let translations: [String: String] = {
        guard let url = Bundle.module.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            assertionFailure("Missing bundled English localization")
            return [:]
        }
        return values
    }()

    /// Explicit source keys keep user text out of localization. Indexed arguments
    /// allow English word order without interpreting percent signs or replacing
    /// placeholder-like text inside filenames, project names or model output.
    public static func tr(_ key: String, _ arguments: [String] = [], language: AppLanguage? = nil) -> String {
        let english = (language ?? self.language) == .english
        var template = english ? translations[key] ?? key : key
        if english, let singular = singularForms[key],
           arguments.indices.contains(singular.index), arguments[singular.index] == "1" {
            template = singular.text
        }
        return render(template, arguments: arguments)
    }

    // English cardinal agreement applies only to authored counts, never to
    // numbers embedded in project names or recognized document text.
    static let singularForms: [String: (index: Int, text: String)] = [
        "{0} 个任务": (0, "{0} task"),
        "{0}，{1}，{2} 个任务": (2, "{0}, {1}, {2} task"),
        "{0} 条": (0, "{0} record"),
        "{0} · {1} 条": (1, "{0} · {1} record"),
        "已准备 {0} 页": (0, "Prepared {0} page"),
        "已载入 {0} 行": (0, "Loaded {0} row"),
        "已更新 {0} 行": (0, "Updated {0} row"),
        "已识别 {0} 条场记": (0, "Recognized {0} slate record"),
        "已载入 {0} 条本地场记": (0, "Loaded {0} local slate record"),
        "已生成 {0} 条本地结果": (0, "Generated {0} local result"),
        "已读取 {0} 条元数据": (0, "Read {0} metadata record"),
        "发现 {0} 个可用模型": (0, "Found {0} available model"),
        "视觉模型 {0} 个": (0, "{0} vision model"),
        "验证 {0} 个候选模型": (0, "Verify {0} candidate model"),
        "识别完成，共 {0} 条记录": (0, "Recognition complete: {0} record")
    ]

    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    private static func render(_ template: String, arguments: [String]) -> String {
        let ns = template as NSString
        var result = ""
        var offset = 0
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let index = Int(ns.substring(with: match.range(at: 1)))!
            result += arguments.indices.contains(index) ? arguments[index] : ns.substring(with: match.range)
            offset = NSMaxRange(match.range)
        }
        result += ns.substring(from: offset)
        return result
    }

    private struct MessagePattern: Sendable {
        let key: String
        let expression: NSRegularExpression
        let indices: [Int]
    }

    /// Only strings authored by domain/workflow code may interpret dynamic
    /// source text as a localizable template. UI templates can contain project
    /// names or document text and must only be rendered through `tr` explicitly.
    static let productMessagePatternKeys: Set<String> = [
        "CSV 中存在多个 {0} 对应列，无法确定应写入哪一列。",
        "CSV 文件超过 {0} MB 上限",
        "CSV 第 {0} 行 {1} 已覆盖：{2}“{3}”→“{4}”。",
        "CSV 第 {0} 行 {1} 已覆盖：{2}。",
        "CSV 第 {0} 行 {1} 的 Comments“{2}”已规范为“{3}”。",
        "CSV 第 {0} 行 {1} 的 {2}“{3}”已规范为“{4}”。",
        "CSV 第 {0} 行的卷名与文件名指向不同素材，已跳过该行。",
        "Sensor FPS 对账：{0} 个已识别且匹配 CSV 的素材没有可用 slate.txt（{1}），其 Camera FPS 保持原值。",
        "Shoot Day 对账：{0} 个已识别且匹配 CSV 的素材没有可用 Shot Date（{1}），其 Shoot Day 保持原值。",
        "{0} {1} 镜的次从 {2} 回落到 {3}",
        "{0} {1} 镜的次从 {2} 跳到 {3}，中间可能漏 {4} 条",
        "{0} 个目录超过配置的 {1} 层搜索范围，未继续进入。",
        "{0} 仅在核心查漏中出现，但最终定向复核未确认，已从结果移除。",
        "{0} 仅由核心查漏识别到，已暂列查漏候选并等待最终定向确认。",
        "{0} 值无效",
        "{0} 只能包含 JSON 快照文件",
        "{0} 在识别结果中出现了互相冲突的场、镜、次或条次状态，这些场记字段已停止写入，请人工校对；有效的 Camera FPS 和 Shoot Day 仍会独立回填。",
        "{0} 已由最终定向复核确认存在，保留为查漏补回记录，请人工复核场/镜/次。",
        "{0} 必须是 {1}–{2} 之间的整数",
        "{0} 必须是无账号、查询参数和片段的 http(s) URL",
        "{0} 必须是有效数字",
        "{0} 数据不完整",
        "{0} 数据不属于当前项目",
        "{0} 数据不属于当前项目库",
        "{0} 文本值无效",
        "{0} 无法读取：{1}",
        "{0} 未在 Resolve CSV 的卷名或文件名中找到，不会新增虚构素材行。",
        "{0} 的 Clip Name“{1}”与文件名指向不同素材",
        "{0} 的 Clip Name“{1}”无法识别",
        "{0} 的 JSON 数据无效",
        "{0} 的 slate.txt 存在互相冲突或无效的 Sensor FPS，Camera FPS 不会写入。",
        "{0} 的 slate.txt 存在互相冲突的 Shot Date，Shoot Day 不会写入。",
        "{0} 的冲突字段最终仍无法确认，已留空，请人工核对。",
        "{0} 的识别冲突已采用第三次定向复核结果。",
        "{0} 缺少可识别的 Clip Name",
        "{0} 缺少有效的 Sensor FPS 或 Shot Date",
        "{0} 超过 {1} MB，已跳过。",
        "{0}/{1} 不属于当前项目",
        "{0}/{1} 不属于当前项目库",
        "不支持当前识别（{0}）",
        "不支持的全局配置项：{0}",
        "与上一条同为 {0} {1} 镜 {2} 次，次序可能重复",
        "主识别重复返回 {0}，已保留第一条。",
        "主识别：{0}",
        "元数据文件来源被多个解析器同时识别：{0}",
        "冲突复核重复返回 {0}，已保留第一条。",
        "冲突复核：{0}",
        "原 CSV 缺少 {0} 列，已按 Resolve 字段名添加。",
        "场记 CSV 超过 {0} MB 上限",
        "场记结构学习失败，已继续使用默认规则：{0}",
        "完整性对账：Resolve CSV 中有 {0} 个素材未在场记识别结果中出现（{1}）。这些行不会自动回填，请检查是否漏页或漏识别。",
        "已完成第 {0} 页（{1}/{2} 页）",
        "已识别 {0} 条场记",
        "快速模式仅执行单次识别，以上 {0} 条序列异常未经过双重校验，建议使用精确模式重新识别。",
        "无法识别的元数据文件来源：{0}",
        "服务端返回 {0} 个模型，当前筛选出 {1} 个视觉模型。",
        "条号从 C{0} 断档到 C{1}，缺少 {2}，可能漏 {3} 条",
        "核心查漏：{0}",
        "模型服务返回 HTTP {0}",
        "正在主识别第 {0}/{1} 页",
        "正在复核第 {0} 页的 {1} 个冲突或查漏候选",
        "正在独立查漏第 {0}/{1} 页",
        "第 {0} 条 {1} 缺少{2}，Scene、Shot、Take 和 Comments 不会写入；有效的 Camera FPS 和 Shoot Day 仍会独立回填。",
        "第 {0} 条缺少卷号，或视频码不是 C0XX 格式，不会写入 CSV。",
        "第 {0} 页 {1} {2} 位于连续条号与同镜次序之间，已将镜/次从 {3} 校正为 {4}/{5}，请人工复核。",
        "第 {0} 页 {1} {2} 的{3}已按同卷条号顺序的上一条记录继承。",
        "第 {0} 页 {1} {2}–{3} 的镜号连续从 {4} 进入下一组，已将疑似漏写十位的 {5} 校正为 {6}，请人工复核。",
        "第 {0} 页未识别到任何视频码。",
        "第 {0} 页：{1}",
        "第 {0}/{1} 页识别失败：{2}",
        "识别完成，共 {0} 条记录",
        "请填写 API 基础地址（Base URL），不要包含 {0} 接口路径。",
        "进入 {0} {1} 镜的第一条次为 {2}，通常应从 1 开始",
        "钥匙串访问未获授权，请解锁钥匙串后重新执行操作 (OSStatus {0})",
        "项目 {0} 缺少 project.sqlite",
        "项目存储包含不支持的文件：{0}",
        "项目存储缺少 {0} 目录",
        "项目数据库缺少 {0} 表",
        "；stderr 尾部：{0}"
    ]

    /// Domain errors and persisted diagnostic events keep their original wire
    /// format. Only their display is translated using complete, anchored authored
    /// message templates. Never call this on arbitrary project/document contents.
    private static let messagePatterns: [MessagePattern] = productMessagePatternKeys.compactMap { key in
        guard translations[key] != nil else { return nil }
        let ns = key as NSString
        let matches = placeholder.matches(in: key, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var pattern = "\\A"
        var offset = 0
        var indices: [Int] = []
        for match in matches {
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            pattern += "([\\s\\S]*?)"
            indices.append(Int(ns.substring(with: match.range(at: 1)))!)
            offset = NSMaxRange(match.range)
        }
        pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: offset)) + "\\z"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return MessagePattern(key: key, expression: expression, indices: indices)
    }.sorted { $0.key.count > $1.key.count }

    public static func message(_ source: String, language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        guard selected == .english else { return source }
        if let exact = translations[source] { return exact }
        guard source.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return source }
        let ns = source as NSString
        for pattern in messagePatterns {
            guard let match = pattern.expression.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { continue }
            var arguments = Array(repeating: "", count: (pattern.indices.max() ?? -1) + 1)
            for (capture, index) in pattern.indices.enumerated() {
                arguments[index] = ns.substring(with: match.range(at: capture + 1))
            }
            // These specific wrappers contain another product diagnostic, not
            // a filename or user-authored record. Translate only those slots.
            let nestedMessages: [String: Int] = [
                "第 {0} 页：{1}": 1, "第 {0}/{1} 页识别失败：{2}": 2,
                "主识别：{0}": 0, "核心查漏：{0}": 0, "冲突复核：{0}": 0
            ]
            if let index = nestedMessages[pattern.key], arguments[index] != source {
                arguments[index] = message(arguments[index], language: selected)
            }
            return tr(pattern.key, arguments, language: selected)
        }
        // Unknown third-party/system errors remain verbatim, never hidden.
        return source
    }
}
