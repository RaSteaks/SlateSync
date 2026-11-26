import CryptoKit
import Foundation
import SlateSyncDomain

public enum MetadataDeliveryFormat: String, CaseIterable, Sendable {
    case csv, ale, fcpxml, xmeml, json

    public var fileExtension: String { self == .xmeml ? "xml" : rawValue }
}

/// Carries recipient-specific preview values from the same snapshot as the bytes.
package struct PreparedMetadata: Sendable {
    package enum Preview: Equatable, Sendable {
        case avid(tape: String, start: String, fps: String)
        case premiere(scene: String, shotTake: String)
    }

    package let data: Data
    package let preview: Preview?
    package let offlineMedia: [String]
    package let files: [String: Data]?

    package init(_ data: Data, preview: Preview? = nil, offlineMedia: [String] = [], files: [String: Data]? = nil) {
        self.files = files
        self.offlineMedia = offlineMedia
        self.data = data
        self.preview = preview
    }
}

package enum DeliveryInputIssue: Error, Sendable {
    case relativeMedia(row: Int)
    case field(row: Int, column: Int?, name: String)

    package var error: SlateSyncError {
        let row: Int, field: String
        switch self {
        case .relativeMedia(let number): (row, field) = (number, "File Path / Clip Directory + File Name")
        case .field(let number, _, let name): (row, field) = (number, name)
        }
        return SlateSyncError(code: "DELIVERY_FIELD", message: "CSV 第 \(row) 行的 \(field) 缺失或不符合交付格式要求。")
    }
}

/// Encodes a frozen, full-width merge result. Presentation order, selection
/// and decorations are never inputs to a delivery file.
public actor MetadataDeliveryEncoder {
    public init() {}

    public func encode(_ table: ResolveCSVTable, as format: MetadataDeliveryFormat, name: String, mediaDirectory: URL? = nil) async throws -> Data {
        // Preserve the existing data-only API for non-interactive callers.
        do { return try await prepare(table, as: format, name: name, mediaDirectory: mediaDirectory).data }
        catch let issue as DeliveryInputIssue { throw issue.error }
    }

    package func prepare(_ table: ResolveCSVTable, as format: MetadataDeliveryFormat, name: String, mediaDirectory: URL? = nil, groupALE: Bool = false) async throws -> PreparedMetadata {
        try Task.checkCancellation()
        switch format {
        case .csv:
            return try await PreparedMetadata(ResolveCSVEngine().encode(table))
        case .json:
            struct Sheet: Encodable {
                let columns: [String]
                let rows: [[String]]
            }
            // Positional values preserve duplicate headers, empty cells and row order.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try PreparedMetadata(encoder.encode(Sheet(columns: table.headers, rows: table.rows)))
        case .ale, .fcpxml, .xmeml:
            let schema = try DeliveryColumns(table.headers)
            guard !table.rows.isEmpty else { throw SlateSyncError(code: "DELIVERY_EMPTY", message: "当前表格没有可交付的素材行。") }
            if format == .ale {
                if groupALE { return try groupedALE(table, schema) }
                return try ale(table, schema)
            }
            return try xml(table, schema, format: format, name: name, mediaDirectory: mediaDirectory)
        }
    }

    private func groupedALE(_ table: ResolveCSVTable, _ columns: DeliveryColumns) throws -> PreparedMetadata {
        // One ALE heading can describe exactly one playback rate and video format.
        // Keep source row numbers for diagnostics after grouping.
        var groups: [String: [Int]] = [:]
        for (index, values) in table.rows.enumerated() {
            try Task.checkCancellation()
            let row = DeliveryRow(values: values, number: index + 2)
            let rate = try row.rate(columns).label
            let video = try row.required(columns.video, "Video Format / Resolution")
            groups[rate + " " + video, default: []].append(index)
        }
        var files: [String: Data] = [:], manifest: [String] = []
        for (offset, group) in groups.keys.sorted().enumerated() {
            guard let indices = groups[group] else { continue }
            let part = ResolveCSVTable(headers: table.headers, rows: indices.map { table.rows[$0] }, format: table.format)
            let bytes = try ale(part, columns, originalRows: indices).data
            let filename = String(format: "group-%03d.ale", offset + 1)
            files[filename] = bytes
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            manifest.append([filename, group, String(indices.count), digest].joined(separator: "\t"))
        }
        let data = Data((manifest.joined(separator: "\n") + "\n").utf8)
        files["manifest.tsv"] = data
        return .init(data, files: files)
    }

    private func ale(_ table: ResolveCSVTable, _ columns: DeliveryColumns, originalRows: [Int]? = nil) throws -> PreparedMetadata {
        let headings = ["Name", "Tracks", "Start", "End", "Tape", "Source File", "Scene", "Shot", "Take", "Comments", "Camera FPS", "Shoot Day"]
        var preview: PreparedMetadata.Preview?
        var projectRate = ""
        var heading = ""
        var body = ""
        for (index, values) in table.rows.enumerated() {
            try Task.checkCancellation()
            let row = DeliveryRow(values: values, number: (originalRows?[index] ?? index) + 2)
            let rate = try row.rate(columns)
            let video = try row.required(columns.video, "Video Format / Resolution")
            let raster = video.lowercased().replacingOccurrences(of: " ", with: "").components(separatedBy: CharacterSet(charactersIn: "x×"))
            let videoFormat = raster.count == 2 && Int(raster[0]) != nil && Int(raster[1]) != nil ? raster[1] : video
            guard videoFormat.rangeOfCharacter(from: .controlCharacters) == nil else { throw row.invalid("Video Format", column: columns.video) }
            let current = "Heading\r\nFIELD_DELIM\tTABS\r\nVIDEO_FORMAT\t\(videoFormat)\r\nFPS\t\(rate.label)"
            if !heading.isEmpty, current != heading {
                if rate.label != projectRate { throw row.invalid("FPS / Frame Rate", column: columns.rate) }
                throw row.invalid("Video Format / Resolution", column: columns.video)
            }
            projectRate = rate.label
            heading = current
            let start = try row.required(columns.start, "Start TC")
            let end = try row.required(columns.end, "End TC")
            guard rate.frames(timecode: start) != nil else { throw row.invalid("Start TC", column: columns.start) }
            guard rate.frames(timecode: end) != nil, start.contains(";") == end.contains(";") else { throw row.invalid("End TC", column: columns.end) }
            let name = try row.name(columns)
            let tracks = try row.tracks(columns)
            let tape = try row.required(columns.reel, "Tape / Reel Name")
            if index == 0 { preview = .avid(tape: tape, start: start, fps: rate.label) }
            let cells = [name, tracks, start, end, tape, row[columns.filename], row[columns.scene], row[columns.shot],
                         row[columns.take], row[columns.comments], row[columns.cameraFPS], row[columns.day]]
            // ALE has no CSV-style quoting. Flatten cell line breaks and tabs
            // so a multiline note cannot create extra records or columns.
            body += cells.map { $0.components(separatedBy: .newlines.union(CharacterSet(charactersIn: "\t"))).joined(separator: " ") }
                .joined(separator: "\t") + "\r\n"
        }
        return PreparedMetadata(Data((heading + "\r\n\r\nColumn\r\n" + headings.joined(separator: "\t") + "\r\n\r\nData\r\n" + body).utf8), preview: preview)
    }

    private func xml(_ table: ResolveCSVTable, _ columns: DeliveryColumns, format: MetadataDeliveryFormat, name: String, mediaDirectory: URL?) throws -> PreparedMetadata {
        func isXMLText(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { scalar in
                let n = scalar.value
                return n == 9 || n == 10 || n == 13 || (n >= 32 && n != 0xfffe && n != 0xffff)
            }
        }
        guard isXMLText(name), table.headers.allSatisfy(isXMLText) else {
            throw DeliveryRow(values: [], number: 1).invalid("XML 1.0")
        }
        var preview: PreparedMetadata.Preview?
        var offlineMedia: [String] = []
        let modern = format == .fcpxml
        let root = XMLElement(name: modern ? "fcpxml" : "xmeml")
        // Version 1.9 is Apple's single-document FCPXML interchange format.
        root.setAttributesWith(["version": modern ? "1.9" : "5"])
        // FCP remembers custom keys across imports. Bind keys to header names
        // so a differently ordered template cannot relabel existing metadata.
        var occurrences: [String: Int] = [:]
        let customKeys = table.headers.map { header in
            occurrences[header, default: 0] += 1
            let token = Data(header.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "com.slatesync.field.\(token).\(occurrences[header, default: 1])"
        }
        let resources = XMLElement(name: "resources")
        let container: XMLElement
        if modern {
            root.addChild(resources)
            container = root.child("event")
            container.setAttributesWith(["name": name])
        } else {
            let project = root.child("project")
            project.child("name", name)
            container = project.child("children")
        }
        for (index, values) in table.rows.enumerated() {
            try Task.checkCancellation()
            let row = DeliveryRow(values: values, number: index + 2)
            // Reject non-XML control codes instead of silently truncating a cell.
            guard values.allSatisfy(isXMLText) else { throw row.invalid("XML 1.0") }
            var url = try row.mediaURL(columns, fallback: mediaDirectory)
            // An absolute path may refer to yesterday's shuttle volume. Preserve
            // its relative hierarchy when the operator selects the new mount.
            if !FileManager.default.isReadableFile(atPath: url.path), let mediaDirectory {
                let parts = url.pathComponents.filter { $0 != "/" }
                let relative = parts.first == "Volumes" ? Array(parts.dropFirst(2)) : Array(parts.dropFirst())
                if !relative.isEmpty {
                    let candidate = relative.reduce(mediaDirectory) { $0.appendingPathComponent($1) }
                    if FileManager.default.isReadableFile(atPath: candidate.path) { url = candidate }
                }
            }
            if !FileManager.default.isReadableFile(atPath: url.path) { offlineMedia.append(url.path) }
            let clipName = row[columns.clipName].isEmpty ? url.lastPathComponent : row[columns.clipName]
            if modern {
                addFCPAsset(row, columns: columns, headers: table.headers, keys: customKeys, id: "r\(index + 1)", clipName: clipName,
                            url: url, resources: resources, event: container)
            } else {
                let shotTake = [row[columns.shot], row[columns.take]].filter { !$0.isEmpty }.joined(separator: "/")
                if index == 0 { preview = .premiere(scene: row[columns.scene], shotTake: shotTake) }
                try addMasterClip(row, shotTake: shotTake, columns: columns, index: index, clipName: clipName, url: url, children: container)
            }
        }
        let document = XMLDocument(rootElement: root)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        let dtd = XMLDTD()
        dtd.name = root.name
        document.dtd = dtd
        return PreparedMetadata(document.xmlData(options: [.nodePrettyPrint]), preview: preview, offlineMedia: offlineMedia)
    }

    private func addFCPAsset(_ row: DeliveryRow, columns: DeliveryColumns, headers: [String], keys: [String], id: String,
                             clipName: String, url: URL, resources: XMLElement, event: XMLElement) {
        let asset = resources.child("asset")
        asset.setAttributesWith(["id": id, "name": clipName])
        asset.child("media-rep").setAttributesWith(["kind": "original-media", "src": url.absoluteString])
        let metadata = asset.child("metadata")
        for (column, header) in headers.enumerated() where !row[column].isEmpty {
            var attributes = ["value": row[column]]
            switch column {
            case columns.scene: attributes["key"] = "com.apple.proapps.scene"
            case columns.take: attributes["key"] = "com.apple.proapps.take"
            case columns.reel: attributes["key"] = "com.apple.proapps.reel"
            default:
                attributes["key"] = keys[column]
                attributes["displayName"] = header
                attributes["source"] = "custom"
                attributes["type"] = "string"
            }
            metadata.child("md").setAttributesWith(attributes)
        }
        let clip = event.child("asset-clip")
        clip.setAttributesWith(["name": clipName, "ref": id])
        if !row[columns.comments].isEmpty { clip.child("note", row[columns.comments]) }
    }

    private func addMasterClip(_ row: DeliveryRow, shotTake: String, columns: DeliveryColumns, index: Int, clipName: String,
                               url: URL, children: XMLElement) throws {
        let rate = try row.rate(columns)
        let length = try row.required(columns.duration, "Duration / Duration (Frames)")
        guard let frames = Int(length) ?? rate.frames(timecode: length), frames > 0 else { throw row.invalid("Duration") }
        let id = "clip-\(index + 1)"
        let clip = children.child("clip")
        clip.setAttributesWith(["id": id])
        clip.child("name", clipName)
        clip.child("duration", String(frames))
        let timing = clip.child("rate")
        timing.child("timebase", String(rate.base))
        timing.child("ntsc", rate.fractional ? "TRUE" : "FALSE")
        clip.child("masterclipid", id)
        clip.child("ismasterclip", "TRUE")
        let log = clip.child("logginginfo")
        log.child("scene", row[columns.scene])
        log.child("shottake", shotTake)
        log.child("shotnote", row[columns.shot])
        log.child("takenote", row[columns.take])
        log.child("lognote", row[columns.comments])
        // XMEML has four standard master comment slots, but no named
        // logging fields for sensor FPS or shoot day. Label these values.
        let comments = clip.child("comments")
        if !row[columns.cameraFPS].isEmpty { comments.child("mastercomment1", "Camera FPS: " + row[columns.cameraFPS]) }
        if !row[columns.day].isEmpty { comments.child("mastercomment2", "Shoot Day: " + row[columns.day]) }
        let file = clip.child("file")
        file.setAttributesWith(["id": "file-\(index + 1)"])
        file.child("name", url.lastPathComponent)
        file.child("pathurl", url.absoluteString)
        let start = row[columns.start]
        if start.isEmpty, !row[columns.reel].isEmpty {
            // XMEML stores tape identity under timecode. Carry the supplied reel
            // independently and let the NLE derive timing from the media.
            file.child("timecode").child("reel").child("name", row[columns.reel])
        }
        if !start.isEmpty {
            guard let frame = rate.frames(timecode: start) else { throw row.invalid("Start TC", column: columns.start) }
            let tc = file.child("timecode")
            tc.child("string", start)
            tc.child("frame", String(frame))
            tc.child("displayformat", start.contains(";") ? "DF" : "NDF")
            if !row[columns.reel].isEmpty { tc.child("reel").child("name", row[columns.reel]) }
        }
    }
}

private extension XMLElement {
    @discardableResult
    func child(_ name: String, _ text: String? = nil) -> XMLElement {
        let element = XMLElement(name: name, stringValue: text)
        addChild(element)
        return element
    }
}

private struct DeliveryColumns {
    let filename, clipName, directory, path, reel, scene, shot, take, comments, cameraFPS, day: Int
    let rate, duration, start, end, tracks, video, type, audioChannels: Int

    init(_ headers: [String]) throws {
        let known = try ResolveHeaders.resolve(headers)
        let normalized = headers.map(ResolveCSVNormalization.normalizeHeader)
        func find(_ aliases: String...) -> Int {
            for key in aliases {
                if let index = normalized.firstIndex(of: ResolveCSVNormalization.normalizeHeader(key)) { return index }
            }
            return -1
        }
        filename = known.fileName.first ?? -1
        clipName = known.clipName.first ?? -1
        directory = known.clipDirectory.first ?? -1
        path = find("File Path", "Source File Path", "文件路径", "素材路径")
        reel = known.reelName.first ?? find("Tape")
        scene = known.scene
        shot = known.shot
        take = known.take
        comments = known.comments
        cameraFPS = known.cameraFPS
        day = known.shootDay
        // Camera FPS can be an overcranked sensor rate; timecodes use playback FPS.
        rate = find("FPS", "Frame Rate", "Video Frame Rate", "Video FPS", "帧率", "幀率")
        duration = find("Duration (Frames)", "Duration in Frames", "Duration", "时长", "持续时间")
        start = find("Start TC", "Start Timecode", "Start", "起始时间码")
        end = find("End TC", "End Timecode", "End", "结束时间码")
        tracks = find("Tracks", "轨道")
        video = find("Video Format", "Resolution", "分辨率")
        type = find("Type", "Clip Type", "类型")
        audioChannels = find("Audio Ch", "Audio Channels", "音频通道数")
    }
}

private struct DeliveryRow {
    let values: [String]
    let number: Int

    subscript(_ column: Int) -> String { values.indices.contains(column) ? values[column] : "" }

    func invalid(_ field: String, column: Int? = nil) -> DeliveryInputIssue {
        .field(row: number, column: column.flatMap { $0 >= 0 ? $0 : nil }, name: field)
    }

    func required(_ index: Int, _ field: String) throws -> String {
        let value = self[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw invalid(field, column: index) }
        return value
    }

    func name(_ columns: DeliveryColumns) throws -> String {
        if !self[columns.clipName].isEmpty { return self[columns.clipName] }
        return try required(columns.filename, "Name / File Name")
    }

    func tracks(_ columns: DeliveryColumns) throws -> String {
        if !self[columns.tracks].isEmpty {
            let tracks = self[columns.tracks].uppercased().trimmingCharacters(in: .whitespaces)
            guard tracks.range(of: #"^(?:V(?:[1-9][0-9]*)?)?(?:A[1-9][0-9]*)*$"#, options: .regularExpression) != nil,
                  !tracks.isEmpty else { throw invalid("Tracks", column: columns.tracks) }
            return tracks
        }
        let type = self[columns.type].lowercased()
        if type == "video" || type == "视频" { return "V" }
        let video = ["video + audio", "video+audio", "视频 + 音频"].contains(type)
        guard video || ["audio", "音频"].contains(type), let count = Int(self[columns.audioChannels]), (1...64).contains(count) else {
            throw invalid("Tracks / Type + Audio Ch")
        }
        return ((video ? ["V"] : []) + (1...count).map { "A\($0)" }).joined()
    }

    func mediaURL(_ columns: DeliveryColumns, fallback: URL?) throws -> URL {
        let file = self[columns.filename]
        let dir = self[columns.directory]
        let full = self[columns.path]
        let raw: String
        if !full.isEmpty { raw = full }
        else if file.hasPrefix("/") || file.hasPrefix("file:") || file.hasPrefix("\\") ||
                    file.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil { raw = file }
        else if !dir.isEmpty, !file.isEmpty {
            if let directory = URL(string: dir), directory.isFileURL { return directory.appendingPathComponent(file) }
            raw = dir + "/" + file
        } else { raw = file }
        if raw.hasPrefix("file:"), let url = URL(string: raw), url.isFileURL, url.path.hasPrefix("/"), !url.hasDirectoryPath { return url }
        // Preserve the host in a network share, including a Windows UNC path.
        let windows = raw.replacingOccurrences(of: "\\", with: "/")
        if windows.hasPrefix("//") {
            let parts = windows.dropFirst(2).split(separator: "/", maxSplits: 1)
            guard parts.count == 2, !windows.hasSuffix("/") else { throw invalid("File Path") }
            var location = URLComponents()
            location.scheme = "file"
            location.host = String(parts[0])
            location.path = "/" + parts[1]
            guard let url = location.url else { throw invalid("File Path") }
            return url
        }
        if raw.hasPrefix("/"), !raw.hasSuffix("/") { return URL(fileURLWithPath: raw) }
        // Windows drive paths are file URLs on the destination system, never
        // relative to the current macOS process working directory.
        if windows.range(of: #"^[A-Za-z]:/.+"#, options: .regularExpression) != nil {
            return URL(fileURLWithPath: "/" + windows)
        }
        if !raw.isEmpty, !raw.hasPrefix("file:"),
           !raw.contains("://"), !raw.hasPrefix("\\"), !windows.hasSuffix("/") {
            // Only a valid relative reference is recoverable with a directory.
            guard let fallback else { throw DeliveryInputIssue.relativeMedia(row: number) }
            return fallback.appendingPathComponent(windows)
        }
        throw invalid("File Path / Clip Directory + File Name")
    }

    func rate(_ columns: DeliveryColumns) throws -> DeliveryRate {
        guard let rate = DeliveryRate(self[columns.rate]) else { throw invalid("FPS / Frame Rate", column: columns.rate) }
        return rate
    }
}

private struct DeliveryRate {
    let base: Int
    let fractional: Bool
    let label: String

    init?(_ raw: String) {
        let value = raw.lowercased().replacingOccurrences(of: "fps", with: "").trimmingCharacters(in: .whitespaces)
        let ratios = value.components(separatedBy: "/")
        let fps: Double?
        if ratios.count == 2, let a = Double(ratios[0]), let b = Double(ratios[1]), b > 0 { fps = a / b }
        else { fps = Double(value) }
        guard let fps, fps.isFinite else { return nil }
        for (base, fractionalLabel) in [(24, "23.976"), (30, "29.97"), (60, "59.94")] where abs(fps - Double(base) * 1000 / 1001) < 0.005 {
            self.base = base
            fractional = true
            label = fractionalLabel
            return
        }
        guard [24, 25, 30, 48, 50, 60].contains(fps) else { return nil }
        base = Int(fps)
        fractional = false
        label = String(base)
    }

    func frames(timecode: String) -> Int? {
        guard timecode.utf8.count == 11, timecode.range(of: #"^[0-9]{2}:[0-9]{2}:[0-9]{2}[:;][0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        let hours = parts[0], minutes = parts[1], seconds = parts[2], frame = parts[3]
        guard hours < 24, minutes < 60, seconds < 60, frame < base else { return nil }
        let totalMinutes = hours * 60 + minutes
        let count = (totalMinutes * 60 + seconds) * base + frame
        guard timecode.contains(";") else { return count }
        guard fractional, base == 30 || base == 60 else { return nil }
        // SMPTE drop-frame skips frame numbers at every minute except each tenth.
        let drop = base == 60 ? 4 : 2
        guard minutes.isMultiple(of: 10) || seconds != 0 || frame >= drop else { return nil }
        return count - drop * (totalMinutes - totalMinutes / 10)
    }
}
