import Foundation
import SlateSyncDomain

/// Canonical SM-07 response schemas. JSONValue keeps the schema typed and
/// Sendable while preserving the exact required/enum contract sent on every
/// provider request.
public enum RecognitionSchemas {
    private static let nullableString: JSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
        "description": .string("无法辨认或原表为空时必须返回 null，不要猜测。"),
    ])

    public static let full: JSONValue = sheetSchema(coreOnly: false)
    public static let core: JSONValue = sheetSchema(coreOnly: true)

    private static func sheetSchema(coreOnly: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [
            "cardNumber": describedNullable("该条素材所属的完整卷号，例如 E001、A001、D001。首字母是摄影机编号，后三位是该摄影机的卷序号。同一页可能包含多个摄影机/卷号，必须按素材所在的 A机/B机/C机/D机子行选择对应卷号。"),
            "videoCode": describedNullable("该卷内的条号，固定格式为 C0XX（C 加三位数字且首位固定为 0）。表格单元格预印 C0，场记只填写后两位；例如填写 15 必须返回 C015，填写 5 返回 C005。不要只返回 15，也不要附加卷号或摄影机文件名后缀。"),
            "scene": describedNullable("场记单“场次”列，将写入 Resolve Scene。单一纯数字场次补足三位，例如“1”返回“001”；如果场次带英文字母后缀，保留后缀并强制转为大写，例如“87a”返回“87A”。如果一个素材同时属于多个场次，必须保留全部场次，并使用两侧各一个空格的斜杠连接；例如场记单“57、58”返回“57 / 58”，场记单“57a/58”返回“57A / 58”，绝不能只返回其中一个。不要返回“场、场次、第”等文字。"),
            "shot": describedNullable("场记单最左侧共用区域的“镜”列。镜号经常在合并单元格中只写一次并覆盖多条“次”，所属多条记录必须返回同一个镜号。只返回完整数字并补足两位，例如“2”返回“02”、“18”返回“18”；绝不能漏掉 10–19 的十位，也不能把当前行“次”列的数字当作镜号。"),
            "take": describedNullable("场记单“次”列，是每条素材行自己的条次数。只返回数字并补足两位，例如“9”返回“09”。同一个镜号下面可以依次出现 01、02、03 等多个次；不要因为镜号单元格留空而把 Take 重置为 01。"),
            "takeStatus": .object([
                "type": .array([.string("string"), .string("null")]),
                "enum": .array([.string("过"), .string("保"), .string("废条"), .null]),
                "description": .string("场记单条次状态标记：☑/√/✓ 返回“过”，三角形/△ 返回“保”，X/× 返回“废条”；单元格无标记或无法确定时返回 null。"),
            ]),
            "confidence": .object([
                "type": .string("string"),
                "enum": .array([.string("high"), .string("medium"), .string("low")]),
                "description": .string("该行整体识别可信度。"),
            ]),
        ]
        if !coreOnly {
            properties["description"] = describedNullable("“拍摄内容”或“内容/视效说明”栏原文。")
            properties["comments"] = describedNullable("“备注”栏原文，仅供人工校对，不会写入 Resolve Comments。只读取最右侧“备注”列；绝不能把“拍摄内容”或“内容/视效说明”栏文字放入此字段。")
            properties["shotSize"] = describedNullable("场记单“景别”列；不要把它误认为 Resolve Scene。")
            properties["cameraPosition"] = describedNullable("场记单中单独的“机位”列内容。A机/B机/C机/D机是摄影机子行标签，不是机位内容。")
        }
        let order = coreOnly
            ? ["cardNumber", "videoCode", "scene", "shot", "take", "takeStatus", "confidence"]
            : ["cardNumber", "videoCode", "scene", "shot", "take", "takeStatus", "description", "comments", "shotSize", "cameraPosition", "confidence"]
        return .object([
            "type": .string("object"),
            "additionalProperties": .boolean(false),
            "properties": .object([
                "sheetTitle": describedNullable("项目名、场记单标题或拍摄日期；无法辨认时为 null。"),
                "records": .object([
                    "type": .string("array"),
                    "description": .string("按页码及场记单从上到下顺序提取的有效拍摄记录。"),
                    "items": .object([
                        "type": .string("object"),
                        "additionalProperties": .boolean(false),
                        "properties": .object(properties),
                        "required": .array(order.map(JSONValue.string)),
                    ]),
                ]),
                "warnings": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("图片质量、表格结构或无法辨认内容的警告。"),
                ]),
            ]),
            "required": .array([.string("sheetTitle"), .string("records"), .string("warnings")]),
        ])
    }

    private static func describedNullable(_ description: String) -> JSONValue {
        guard case .object(var fields) = nullableString else { return nullableString }
        fields["description"] = .string(description)
        return .object(fields)
    }
}
