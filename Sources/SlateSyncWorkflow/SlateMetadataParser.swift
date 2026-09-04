import Foundation
import SlateSyncDomain

/// Registry-backed parser for v1 camera sidecars. Unsupported names fail
/// closed so arbitrary files are never interpreted as camera metadata.
public enum SlateMetadataParser {
    public static func supports(sourceName: String) -> Bool {
        sourceName.lowercased().hasSuffix("slate.txt")
    }

    public static func parse(_ data: Data, sourceName: String = "slate.txt") throws -> ScannedSlateMetadata {
        guard supports(sourceName: sourceName) else {
            throw SlateSyncError(code: "METADATA_UNSUPPORTED", message: "无法识别的元数据文件来源：\(sourceName)")
        }
        let text = try decode(data)
        var fields: [String: String] = [:]
        for line in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: CharacterSet.newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rawKey = line[..<colon].replacingOccurrences(of: #"[.\s]+$"#, with: "", options: .regularExpression)
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, fields[key] == nil { fields[key] = value }
        }

        let clipName = fields["clip name"] ?? ""
        let clipKey = ResolveCSVNormalization.extractCombinedMaterialKey(clipName)
        let sourceBase = sourceName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? sourceName
        let sourceKey = ResolveCSVNormalization.extractCombinedMaterialKey(sourceBase)
        if fields["clip name"] != nil, clipKey.isEmpty {
            throw SlateSyncError(code: "METADATA_CLIP", message: "\(sourceName) 的 Clip Name“\(clipName)”无法识别")
        }
        if !clipKey.isEmpty, !sourceKey.isEmpty, clipKey != sourceKey {
            throw SlateSyncError(code: "METADATA_CONFLICT", message: "\(sourceName) 的 Clip Name“\(clipName)”与文件名指向不同素材")
        }
        let key = clipKey.isEmpty ? sourceKey : clipKey
        guard !key.isEmpty else { throw SlateSyncError(code: "METADATA_CLIP", message: "\(sourceName) 缺少可识别的 Clip Name") }
        let fps = ResolveCSVNormalization.normalizeCameraFPS(fields["sensor fps"])
        let day = ResolveCSVNormalization.normalizeShootDay(fields["shot date"])
        guard !fps.isEmpty || !day.isEmpty else {
            throw SlateSyncError(code: "METADATA_FIELDS", message: "\(sourceName) 缺少有效的 Sensor FPS 或 Shot Date")
        }
        return ScannedSlateMetadata(
            sourceName: sourceName,
            clipName: clipName.isEmpty ? ResolveCSVNormalization.canonicalKeyToMaterialPrefix(key) : clipName,
            materialKey: key,
            sensorFps: fps,
            shootDay: day
        )
    }

    private static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw SlateSyncError(code: "METADATA_EMPTY", message: "slate.txt 文件为空") }
        let bytes = [UInt8](data.prefix(3))
        let encoding: String.Encoding
        let prefix: Int
        if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; prefix = 2 }
        else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; prefix = 2 }
        else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8; prefix = 3 }
        else {
            let sample = [UInt8](data.prefix(2048))
            let even = sample.indices.filter { $0.isMultiple(of: 2) && sample[$0] == 0 }.count
            let odd = sample.indices.filter { !$0.isMultiple(of: 2) && sample[$0] == 0 }.count
            encoding = odd > sample.count / 8 && odd > even * 4 ? .utf16LittleEndian
                : even > sample.count / 8 && even > odd * 4 ? .utf16BigEndian : .utf8
            prefix = 0
        }
        guard let text = String(data: data.dropFirst(prefix), encoding: encoding) else {
            throw SlateSyncError(code: "METADATA_ENCODING", message: "无法读取 slate.txt 编码；仅支持 UTF-8 或 UTF-16 文本。")
        }
        return text
    }
}
