import Foundation
import SlateSyncDomain

/// Read-only, bounded metadata traversal. URL resource values are inspected
/// without following symbolic links, and all externally visible ordering is
/// normalized so filesystem enumeration cannot change compatibility output.
public actor SlateMetadataScanner: SlateMetadataScanning {
    private struct Candidate: Sendable { let url: URL; let sourceName: String }

    public init() {}

    public func scan(directory: URL, options: SlateMetadataScanOptions) async throws -> ScanResult {
        let expected = Set(options.expectedKeys)
        guard !expected.isEmpty else {
            throw SlateSyncError(code: "METADATA_EXPECTED_KEYS", message: "Resolve CSV 中没有可用于查找 slate.txt 的素材编号")
        }
        guard let rootValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SlateSyncError(code: "METADATA_DIRECTORY", message: "元数据扫描根目录无效或不安全")
        }
        let manager = FileManager.default
        var candidates: [Candidate] = []
        var structures: [String: [MetadataNameTemplate]] = [:]
        var warnings: [String] = []
        var visited = 0
        var pruned = 0
        var skippedDeep = 0
        var discovered = 0
        var read = 0
        var learned = 0
        let rootName = directory.lastPathComponent.isEmpty ? "素材根目录" : directory.lastPathComponent

        func entries(_ url: URL, source: String) -> [URL] {
            do {
                return try manager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch {
                warnings.append("\(source) 无法读取：\(error.localizedDescription)")
                return []
            }
        }

        func walk(_ current: URL, parts: [String], depth: Int, root: Bool = false) throws {
            try Task.checkCancellation()
            visited += 1
            let directoryName = parts.last ?? ""
            let directoryKey = root ? "" : ResolveCSVNormalization.extractCombinedMaterialKey(directoryName)
            if !directoryKey.isEmpty {
                guard expected.contains(directoryKey) else { pruned += 1; return }
                let camera = directoryKey.split(separator: ":").first.map(String.init) ?? ""
                let templates = structures[camera] ?? MetadataStructure.defaultTemplates()
                structures[camera] = templates
                for name in MetadataStructure.probeNames(templates, directoryName: directoryName) {
                    let url = current.appending(path: name)
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    candidates.append(Candidate(url: url, sourceName: (parts + [name]).joined(separator: "/")))
                    discovered += 1
                    return
                }
                let found = entries(current, source: parts.joined(separator: "/")).filter { url in
                    guard SlateMetadataParser.supports(sourceName: url.lastPathComponent),
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }
                if !found.isEmpty {
                    structures[camera] = MetadataStructure.learn(directoryName: directoryName, metadataFileNames: found.map(\.lastPathComponent))
                    learned += 1
                    for url in found {
                        candidates.append(Candidate(url: url, sourceName: (parts + [url.lastPathComponent]).joined(separator: "/")))
                        discovered += 1
                    }
                }
                return
            }

            for entry in entries(current, source: parts.joined(separator: "/")) {
                try Task.checkCancellation()
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                if values.isRegularFile == true, SlateMetadataParser.supports(sourceName: entry.lastPathComponent) {
                    let fileKey = ResolveCSVNormalization.extractCombinedMaterialKey(entry.lastPathComponent)
                    if fileKey.isEmpty || expected.contains(fileKey) {
                        candidates.append(Candidate(url: entry, sourceName: (parts + [entry.lastPathComponent]).joined(separator: "/")))
                        discovered += 1
                    }
                } else if values.isDirectory == true {
                    let childKey = ResolveCSVNormalization.extractCombinedMaterialKey(entry.lastPathComponent)
                    if !childKey.isEmpty, !expected.contains(childKey) { pruned += 1 }
                    else if depth >= options.maxDepth { skippedDeep += 1 }
                    else { try walk(entry, parts: parts + [entry.lastPathComponent], depth: depth + 1) }
                }
            }
        }

        try walk(directory.standardizedFileURL, parts: [rootName], depth: 0, root: true)
        var metadata: [ScannedSlateMetadata] = []
        for candidate in candidates.sorted(by: { $0.sourceName < $1.sourceName }) {
            try Task.checkCancellation()
            do {
                let values = try candidate.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if (values.fileSize ?? 0) > options.maxFileBytes {
                    warnings.append("\(candidate.sourceName) 超过 \(options.maxFileBytes / 1024 / 1024) MB，已跳过。")
                    continue
                }
                read += 1
                metadata.append(try SlateMetadataParser.parse(Data(contentsOf: candidate.url, options: [.mappedIfSafe]), sourceName: candidate.sourceName))
            } catch {
                warnings.append((error as? SlateSyncError)?.message ?? error.localizedDescription)
            }
        }
        let found = Set(metadata.map(\.materialKey))
        let missing = expected.subtracting(found).sorted(by: ResolveCSVNormalization.compareMaterialKeys)
        if skippedDeep > 0 { warnings.append("\(skippedDeep) 个目录超过配置的 \(options.maxDepth) 层搜索范围，未继续进入。") }
        return ScanResult(
            metadata: metadata,
            warnings: warnings,
            stats: ScanStats(visitedDirectories: visited, prunedDirectories: pruned, skippedDeepDirectories: skippedDeep, discoveredSlateFiles: discovered, readSlateFiles: read, learnedStructures: learned),
            missingKeys: missing
        )
    }
}
