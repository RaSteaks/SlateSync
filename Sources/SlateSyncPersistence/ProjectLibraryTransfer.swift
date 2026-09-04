import Foundation
import SlateSyncDomain

public struct ProjectPackageProject: Codable, Hashable, Sendable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let description: String
    public let archivedAt: String?
    public let createdAt: String
    public let updatedAt: String

    init(
        id: String,
        libraryId: String,
        name: String,
        description: String,
        archivedAt: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.libraryId = libraryId
        self.name = name
        self.description = description
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case libraryId
        case name
        case description
        case archivedAt
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        libraryId = try values.decode(String.self, forKey: .libraryId)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decode(String.self, forKey: .description)
        archivedAt = try values.decodeIfPresent(String.self, forKey: .archivedAt)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(libraryId, forKey: .libraryId)
        try values.encode(name, forKey: .name)
        try values.encode(description, forKey: .description)
        // Electron's normalized package record always carries archivedAt,
        // including an explicit JSON null for active projects.
        try values.encode(archivedAt, forKey: .archivedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct ProjectPackageInfo: Hashable, Sendable {
    public let path: String
    public let formatVersion: Int
    public let project: ProjectPackageProject
    public let taskCount: Int
    public let diagnosticCount: Int
}

private struct ProjectPackageManifest: Codable {
    let type: String
    let formatVersion: Int
    let project: ProjectPackageProject
}

/// Portable v1 transfer boundary shared by the Library composition root and
/// future native dialogs. External trees are fully checked before SQLite is
/// opened, while exports use staging plus online backup for atomic, WAL-free
/// packages that Electron v1 can reopen directly.
public enum ProjectLibraryTransfer {
    public static let projectExtension = ".slatesync-project"
    public static let projectPackageManifest = "slatesync-project.json"

    public static func validateLibrary(
        at libraryURL: URL,
        requireExtension: Bool = true
    ) async throws -> ValidatedLibraryInfo {
        let root = libraryURL.standardizedFileURL
        try requireDirectory(root, code: "INVALID_PROJECT_LIBRARY", message: "请选择有效的 .slatesync-library 项目库目录")
        if requireExtension, !root.lastPathComponent.hasSuffix(ProjectLibraryStore.libraryExtension) {
            throw transferError("INVALID_PROJECT_LIBRARY", "项目库目录必须以 .slatesync-library 结尾")
        }
        try assertNoSymbolicLinks(in: root, code: "INVALID_PROJECT_LIBRARY", message: "项目库不能包含符号链接")

        let manifest: LibraryV1Manifest
        do {
            manifest = try JSONDecoder().decode(
                LibraryV1Manifest.self,
                from: Data(contentsOf: root.appending(path: "library.json"))
            )
        } catch {
            throw transferError("INVALID_PROJECT_LIBRARY", "无法读取 library.json")
        }
        guard (1...ProjectLibraryStore.libraryFormatVersion).contains(manifest.formatVersion),
              isLibraryID(manifest.id) else {
            throw transferError("INVALID_PROJECT_LIBRARY", "项目库清单或格式版本无效")
        }

        let databaseURL = root.appending(path: SQLiteV1.libraryDatabaseFilename)
        guard isRegularFile(databaseURL) else {
            throw transferError("INVALID_PROJECT_LIBRARY", "项目库缺少 library.sqlite")
        }
        let database = try SQLiteDatabase(url: databaseURL, mode: .readOnly)
        do {
            guard try await database.scalar("PRAGMA integrity_check;") == "ok" else {
                throw transferError("INVALID_PROJECT_LIBRARY", "项目库索引完整性检查失败")
            }
            let rows = try await database.rows("SELECT id, relative_path FROM projects;")
            for row in rows {
                guard let id = row["id"] ?? nil,
                      let relativePath = row["relative_path"] ?? nil,
                      (try? PersistenceIdentifiers.project(id)) != nil else {
                    throw transferError("INVALID_PROJECT_LIBRARY", "项目索引记录无效")
                }
                let project = try checkedProjectURL(root: root, relativePath: relativePath)
                guard isRegularFile(project.appending(path: SQLiteV1.projectDatabaseFilename)) else {
                    throw transferError("INVALID_PROJECT_LIBRARY", "项目 \(id) 缺少 project.sqlite")
                }
            }
            try await database.close()
            return ValidatedLibraryInfo(
                id: manifest.id,
                name: manifest.name,
                formatVersion: manifest.formatVersion,
                path: root.path,
                projectCount: rows.count
            )
        } catch {
            try? await database.close()
            if let error = error as? SlateSyncError, error.code == "INVALID_PROJECT_LIBRARY" { throw error }
            throw transferError("INVALID_PROJECT_LIBRARY", "无法读取项目库索引")
        }
    }

    public static func validateProjectPackage(
        at packageURL: URL,
        requireExtension: Bool = true
    ) async throws -> ProjectPackageInfo {
        let root = packageURL.standardizedFileURL
        try requireDirectory(root, code: "INVALID_PROJECT_PACKAGE", message: "请选择有效的 .slatesync-project 项目目录")
        if requireExtension, !root.lastPathComponent.lowercased().hasSuffix(projectExtension) {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目目录必须以 .slatesync-project 结尾")
        }
        try assertNoSymbolicLinks(in: root, code: "INVALID_PROJECT_PACKAGE", message: "项目包不能包含符号链接")
        try assertProjectShape(root, package: true, allowSQLiteArtifacts: false)

        let packageManifest: ProjectPackageManifest
        let storageManifest: ProjectV1Manifest
        do {
            packageManifest = try JSONDecoder().decode(
                ProjectPackageManifest.self,
                from: Data(contentsOf: root.appending(path: projectPackageManifest))
            )
            storageManifest = try JSONDecoder().decode(
                ProjectV1Manifest.self,
                from: Data(contentsOf: root.appending(path: "project.json"))
            )
        } catch {
            throw transferError("INVALID_PROJECT_PACKAGE", "无法读取项目包清单")
        }
        guard packageManifest.type == "slatesync-project",
              (1...ProjectLibraryStore.projectFormatVersion).contains(packageManifest.formatVersion) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目包类型或格式版本无效")
        }
        try validateProject(packageManifest.project)
        try validateStorageManifest(storageManifest, expected: packageManifest.project)
        try validateSnapshots(at: root, expected: packageManifest.project)
        let counts = try await inspectProjectDatabase(
            at: root.appending(path: SQLiteV1.projectDatabaseFilename),
            expected: packageManifest.project,
            storageManifest: storageManifest
        )
        return ProjectPackageInfo(
            path: root.path,
            formatVersion: packageManifest.formatVersion,
            project: packageManifest.project,
            taskCount: counts.tasks,
            diagnosticCount: counts.diagnostics
        )
    }

    public static func exportLibrary(from sourceURL: URL, to targetURL: URL) async throws -> ValidatedLibraryInfo {
        let source = sourceURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        _ = try await validateLibrary(at: source, requireExtension: false)
        guard target.lastPathComponent.hasSuffix(ProjectLibraryStore.libraryExtension) else {
            throw transferError("INVALID_PROJECT_LIBRARY", "导出路径必须以 .slatesync-library 结尾")
        }
        try assertSeparate(source: source, target: target, code: "INVALID_LIBRARY_DESTINATION")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw transferError("LIBRARY_DESTINATION_EXISTS", "目标位置已存在同名项目库")
        }
        let staging = target.deletingLastPathComponent().appending(
            path: ".partial-\(UUID().uuidString.lowercased())-\(target.lastPathComponent)",
            directoryHint: .isDirectory
        )
        do {
            try copyPortableTree(from: source, to: staging)
            try await backupSQLiteTree(from: source, to: staging)
            let info = try await validateLibrary(at: staging)
            try FileManager.default.moveItem(at: staging, to: target)
            return ValidatedLibraryInfo(
                id: info.id,
                name: info.name,
                formatVersion: info.formatVersion,
                path: target.path,
                projectCount: info.projectCount
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func exportProject(
        from sourceURL: URL,
        project: ProjectPackageProject,
        to targetURL: URL,
        writer: any AtomicFileWriting
    ) async throws -> ProjectPackageInfo {
        let source = sourceURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        try validateProject(project)
        try requireDirectory(source, code: "INVALID_PROJECT_PACKAGE", message: "项目存储目录无效")
        try assertNoSymbolicLinks(in: source, code: "INVALID_PROJECT_PACKAGE", message: "项目包不能包含符号链接")
        try assertProjectShape(source, package: false, allowSQLiteArtifacts: true)
        let storage = try decodeStorageManifest(at: source)
        try validateStorageManifest(storage, expected: project)
        try validateSnapshots(at: source, expected: project)
        _ = try await inspectProjectDatabase(
            at: source.appending(path: SQLiteV1.projectDatabaseFilename),
            expected: project,
            storageManifest: storage
        )
        guard target.lastPathComponent.lowercased().hasSuffix(projectExtension) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "导出路径必须以 .slatesync-project 结尾")
        }
        try assertSeparate(source: source, target: target, code: "INVALID_PROJECT_DESTINATION")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw transferError("PROJECT_DESTINATION_EXISTS", "目标位置已存在同名项目")
        }
        let staging = target.deletingLastPathComponent().appending(
            path: ".partial-\(UUID().uuidString.lowercased())-\(target.lastPathComponent)",
            directoryHint: .isDirectory
        )
        do {
            try copyPortableTree(from: source, to: staging, skippedNames: [projectPackageManifest])
            try await backupSQLiteTree(from: source, to: staging)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try writer.writeAtomically(
                encoder.encode(ProjectPackageManifest(type: "slatesync-project", formatVersion: 1, project: project)),
                to: staging.appending(path: projectPackageManifest),
                permissions: 0o600
            )
            let info = try await validateProjectPackage(at: staging)
            try FileManager.default.moveItem(at: staging, to: target)
            return ProjectPackageInfo(
                path: target.path,
                formatVersion: info.formatVersion,
                project: info.project,
                taskCount: info.taskCount,
                diagnosticCount: info.diagnosticCount
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func importProjectData(
        from packageURL: URL,
        to targetURL: URL,
        projectID: String,
        libraryID: String,
        writer: any AtomicFileWriting
    ) async throws -> ProjectPackageProject {
        let info = try await validateProjectPackage(at: packageURL)
        let target = targetURL.standardizedFileURL
        _ = try PersistenceIdentifiers.project(projectID)
        guard isLibraryID(libraryID) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目库 ID 无效")
        }
        try assertSeparate(
            source: URL(fileURLWithPath: info.path),
            target: target,
            code: "INVALID_PROJECT_DESTINATION"
        )
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw transferError("PROJECT_DESTINATION_EXISTS", "导入目标项目目录已存在")
        }
        let staging = target.deletingLastPathComponent().appending(
            path: ".partial-\(UUID().uuidString.lowercased())-\(target.lastPathComponent)",
            directoryHint: .isDirectory
        )
        do {
            let source = URL(fileURLWithPath: info.path)
            try copyPortableTree(from: source, to: staging, skippedNames: [projectPackageManifest])
            try await backupSQLiteTree(from: source, to: staging)
            let rebound = try await rebindProject(
                at: staging,
                source: info.project,
                projectID: projectID,
                libraryID: libraryID,
                writer: writer
            )
            try FileManager.default.moveItem(at: staging, to: target)
            return rebound
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func rebindProject(
        at root: URL,
        source: ProjectPackageProject,
        projectID: String,
        libraryID: String,
        writer: any AtomicFileWriting
    ) async throws -> ProjectPackageProject {
        var storage = try decodeStorageManifest(at: root)
        let database = try SQLiteDatabase(
            url: root.appending(path: SQLiteV1.projectDatabaseFilename),
            mode: .readWriteExisting
        )
        do {
            var commands = [
                SQLiteCommand("UPDATE project_meta SET value = ? WHERE key = 'project_id';", bindings: [projectID]),
                SQLiteCommand("UPDATE project_meta SET value = ? WHERE key = 'library_id';", bindings: [libraryID]),
                SQLiteCommand("UPDATE project_meta SET value = ? WHERE key = 'name';", bindings: [source.name]),
                SQLiteCommand("UPDATE project_meta SET value = ? WHERE key = 'description';", bindings: [source.description]),
                SQLiteCommand(
                    "UPDATE project_meta SET value = ? WHERE key = 'archived_at';",
                    bindings: [try nullableJSONString(source.archivedAt)]
                ),
            ]
            for table in ["tasks", "diagnostic_sessions"] {
                for row in try await database.rows("SELECT id, data_json FROM \(table);") {
                    guard let id = row["id"] ?? nil, let json = row["data_json"] ?? nil else {
                        throw transferError("INVALID_PROJECT_PACKAGE", "\(table) 数据不完整")
                    }
                    commands.append(SQLiteCommand(
                        "UPDATE \(table) SET data_json = ? WHERE id = ?;",
                        bindings: [try reboundJSON(json, projectID: projectID, libraryID: libraryID), id]
                    ))
                }
            }
            try await database.transaction(commands)
            try await database.close()
        } catch {
            try? await database.close()
            throw error
        }

        storage = ProjectV1Manifest(
            id: projectID,
            libraryId: libraryID,
            name: source.name,
            description: source.description,
            formatVersion: storage.formatVersion,
            createdAt: storage.createdAt,
            updatedAt: storage.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writer.writeAtomically(
            encoder.encode(storage),
            to: root.appending(path: "project.json"),
            permissions: 0o600
        )
        for directoryName in ["tasks", "diagnostics"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard !isTemporary(file.lastPathComponent), file.pathExtension.lowercased() == "json" else { continue }
                let data = try Data(contentsOf: file)
                guard var object = try? PersistenceJSON.object(from: data, errorCode: "INVALID_PROJECT_PACKAGE") else {
                    // Malformed v1 snapshots remain opaque compatibility evidence.
                    continue
                }
                object["projectId"] = projectID
                object["libraryId"] = libraryID
                try writer.writeAtomically(
                    PersistenceJSON.data(from: object, errorCode: "INVALID_PROJECT_PACKAGE"),
                    to: file,
                    permissions: 0o600
                )
            }
        }
        let rebound = ProjectPackageProject(
            id: projectID,
            libraryId: libraryID,
            name: source.name,
            description: source.description,
            archivedAt: source.archivedAt,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt
        )
        try validateSnapshots(at: root, expected: rebound)
        _ = try await inspectProjectDatabase(
            at: root.appending(path: SQLiteV1.projectDatabaseFilename),
            expected: rebound,
            storageManifest: storage
        )
        return rebound
    }

    private static func inspectProjectDatabase(
        at url: URL,
        expected: ProjectPackageProject,
        storageManifest: ProjectV1Manifest
    ) async throws -> (tasks: Int, diagnostics: Int) {
        guard isRegularFile(url) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目存储缺少 project.sqlite")
        }
        let database = try SQLiteDatabase(url: url, mode: .readOnly)
        do {
            guard try await database.scalar("PRAGMA integrity_check;") == "ok" else {
                throw transferError("INVALID_PROJECT_PACKAGE", "项目数据库完整性检查失败")
            }
            for table in ["project_meta", "tasks", "diagnostic_sessions", "scenario_profiles", "scenario_observations"] {
                guard try await database.scalar(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
                    bindings: [table]
                ) != nil else {
                    throw transferError("INVALID_PROJECT_PACKAGE", "项目数据库缺少 \(table) 表")
                }
            }
            let metaRows = try await database.rows("SELECT key, value FROM project_meta;")
            let metadata = Dictionary(uniqueKeysWithValues: metaRows.compactMap { row -> (String, String)? in
                guard let key = row["key"] ?? nil, let value = row["value"] ?? nil else { return nil }
                return (key, value)
            })
            let required = ["project_id", "library_id", "name", "description", "settings", "created_at", "updated_at", "archived_at", "schema_version"]
            guard required.allSatisfy({ metadata[$0] != nil }),
                  metadata["project_id"] == expected.id,
                  metadata["library_id"] == expected.libraryId,
                  metadata["name"] == expected.name,
                  metadata["description"] == expected.description,
                  metadata["created_at"] == storageManifest.createdAt,
                  metadata["updated_at"] == storageManifest.updatedAt,
                  Int(metadata["schema_version"] ?? "") == ProjectLibraryStore.projectFormatVersion,
                  try jsonObject(metadata["settings"] ?? "") != nil,
                  try nullableJSONStringValue(metadata["archived_at"] ?? "") == expected.archivedAt else {
                throw transferError("INVALID_PROJECT_PACKAGE", "项目数据库资料与清单不一致")
            }
            let taskCount = try await validateOwnedRows(in: database, table: "tasks", expected: expected)
            let diagnosticCount = try await validateOwnedRows(in: database, table: "diagnostic_sessions", expected: expected)
            try await database.close()
            return (taskCount, diagnosticCount)
        } catch {
            try? await database.close()
            if let error = error as? SlateSyncError, error.code == "INVALID_PROJECT_PACKAGE" { throw error }
            throw transferError("INVALID_PROJECT_PACKAGE", "无法读取项目包数据库")
        }
    }

    private static func validateOwnedRows(
        in database: SQLiteDatabase,
        table: String,
        expected: ProjectPackageProject
    ) async throws -> Int {
        let rows = try await database.rows("SELECT id, data_json FROM \(table);")
        for row in rows {
            guard let json = row["data_json"] ?? nil,
                  let object = try jsonObject(json) else {
                throw transferError("INVALID_PROJECT_PACKAGE", "\(table) 的 JSON 数据无效")
            }
            if let projectID = object["projectId"] {
                guard projectID as? String == expected.id else {
                    throw transferError("INVALID_PROJECT_PACKAGE", "\(table) 数据不属于当前项目")
                }
            }
            if let libraryID = object["libraryId"] {
                guard libraryID as? String == expected.libraryId else {
                    throw transferError("INVALID_PROJECT_PACKAGE", "\(table) 数据不属于当前项目库")
                }
            }
        }
        return rows.count
    }

    private static func validateProject(_ project: ProjectPackageProject) throws {
        _ = try PersistenceIdentifiers.project(project.id)
        let trimmedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = project.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLibraryID(project.libraryId),
              !trimmedName.isEmpty,
              project.name == trimmedName,
              project.description == trimmedDescription,
              project.name.utf16.count <= 80,
              project.description.utf16.count <= 500,
              isTimestamp(project.createdAt), isTimestamp(project.updatedAt),
              project.archivedAt.map(isTimestamp) ?? true else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目包 project 资料无效")
        }
    }

    private static func validateStorageManifest(
        _ storage: ProjectV1Manifest,
        expected: ProjectPackageProject
    ) throws {
        guard storage.formatVersion == ProjectLibraryStore.projectFormatVersion,
              storage.id == expected.id,
              storage.libraryId == expected.libraryId,
              storage.name == expected.name,
              storage.description == expected.description,
              isTimestamp(storage.createdAt), isTimestamp(storage.updatedAt) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "project.json 与项目包清单不一致")
        }
    }

    private static func decodeStorageManifest(at root: URL) throws -> ProjectV1Manifest {
        do {
            return try JSONDecoder().decode(
                ProjectV1Manifest.self,
                from: Data(contentsOf: root.appending(path: "project.json"))
            )
        } catch {
            throw transferError("INVALID_PROJECT_PACKAGE", "无法读取项目存储中的 project.json")
        }
    }

    private static func validateSnapshots(at root: URL, expected: ProjectPackageProject) throws {
        for directoryName in ["tasks", "diagnostics"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard !isTemporary(file.lastPathComponent) else { continue }
                let data = try Data(contentsOf: file)
                guard let object = try? PersistenceJSON.object(from: data, errorCode: "INVALID_PROJECT_PACKAGE") else {
                    continue
                }
                if let projectID = object["projectId"] {
                    guard projectID as? String == expected.id else {
                        throw transferError("INVALID_PROJECT_PACKAGE", "\(directoryName)/\(file.lastPathComponent) 不属于当前项目")
                    }
                }
                if let libraryID = object["libraryId"] {
                    guard libraryID as? String == expected.libraryId else {
                        throw transferError("INVALID_PROJECT_PACKAGE", "\(directoryName)/\(file.lastPathComponent) 不属于当前项目库")
                    }
                }
            }
        }
    }

    private static func assertProjectShape(
        _ root: URL,
        package: Bool,
        allowSQLiteArtifacts: Bool
    ) throws {
        var allowed: Set<String> = ["project.json", SQLiteV1.projectDatabaseFilename, "tasks", "diagnostics"]
        if package { allowed.insert(projectPackageManifest) }
        if allowSQLiteArtifacts {
            allowed.formUnion(["project.sqlite-wal", "project.sqlite-shm"])
        }
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if isTemporary(entry.lastPathComponent) { continue }
            guard allowed.contains(entry.lastPathComponent) else {
                throw transferError("INVALID_PROJECT_PACKAGE", "项目存储包含不支持的文件：\(entry.lastPathComponent)")
            }
        }
        for directoryName in ["tasks", "diagnostics"] {
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            try requireDirectory(directory, code: "INVALID_PROJECT_PACKAGE", message: "项目存储缺少 \(directoryName) 目录")
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if isTemporary(entry.lastPathComponent) { continue }
                guard isRegularFile(entry), entry.pathExtension.lowercased() == "json" else {
                    throw transferError("INVALID_PROJECT_PACKAGE", "\(directoryName) 只能包含 JSON 快照文件")
                }
            }
        }
        guard isRegularFile(root.appending(path: "project.json")),
              isRegularFile(root.appending(path: SQLiteV1.projectDatabaseFilename)) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目存储缺少 project.json 或 project.sqlite")
        }
    }

    private static func copyPortableTree(
        from source: URL,
        to target: URL,
        skippedNames: Set<String> = []
    ) throws {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw transferError("INVALID_PROJECT_PACKAGE", "传输树不能包含符号链接")
        }
        if isTemporary(source.lastPathComponent) { return }
        if values.isDirectory == true {
            try SecureFilePermissions.prepareDirectory(at: target)
            for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyPortableTree(
                    from: entry,
                    to: target.appending(path: entry.lastPathComponent),
                    skippedNames: skippedNames
                )
            }
            return
        }
        guard values.isRegularFile == true,
              !isSQLiteArtifact(source.lastPathComponent),
              !skippedNames.contains(source.lastPathComponent) else { return }
        try SecureFilePermissions.prepareDirectory(at: target.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: target)
        try SecureFilePermissions.repairFile(at: target, permissions: 0o600)
    }

    private static func backupSQLiteTree(from sourceRoot: URL, to targetRoot: URL) async throws {
        let canonicalRoot = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false }
        )
        while let source = enumerator?.nextObject() as? URL {
            if isTemporary(source.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw transferError("INVALID_PROJECT_PACKAGE", "传输树不能包含符号链接")
            }
            guard values.isRegularFile == true, source.pathExtension.lowercased() == "sqlite" else { continue }
            // FileManager may canonicalize `/var` to `/private/var` in yielded
            // URLs. Resolve both sides before deriving the relative path so a
            // backup can never escape into a truncated sibling component.
            let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalSource.path.hasPrefix(canonicalRoot.path + "/") else {
                throw transferError("INVALID_PROJECT_PACKAGE", "SQLite 备份路径越过传输边界")
            }
            let relative = String(canonicalSource.path.dropFirst(canonicalRoot.path.count + 1))
            let target = targetRoot.appending(path: relative)
            let database = try SQLiteDatabase(url: source, mode: .readOnly)
            do {
                try await database.backup(to: target)
                try await database.close()
            } catch {
                try? await database.close()
                throw error
            }
        }
    }

    private static func assertNoSymbolicLinks(in directory: URL, code: String, message: String) throws {
        let rootValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { throw transferError(code, message) }
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        )
        while let entry = enumerator?.nextObject() as? URL {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw transferError(code, message)
            }
        }
    }

    private static func checkedProjectURL(root: URL, relativePath: String) throws -> URL {
        let projectsRoot = root.appending(path: "Projects", directoryHint: .isDirectory).standardizedFileURL
        let candidate = root.appending(path: relativePath).standardizedFileURL
        guard candidate.path == projectsRoot.path || candidate.path.hasPrefix(projectsRoot.path + "/") else {
            throw transferError("INVALID_PROJECT_LIBRARY", "项目索引包含越过 Library 边界的路径")
        }
        return candidate
    }

    private static func assertSeparate(source: URL, target: URL, code: String) throws {
        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard sourcePath != targetPath,
              !targetPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(targetPath + "/") else {
            throw transferError(code, "传输位置不能与源目录重叠")
        }
    }

    private static func requireDirectory(_ url: URL, code: String, message: String) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw transferError(code, message)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func isSQLiteArtifact(_ name: String) -> Bool {
        name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm")
    }

    private static func isTemporary(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".tmp")
    }

    private static func isLibraryID(_ value: String) -> Bool {
        value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func isTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func jsonObject(_ string: String) throws -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nullableJSONString(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "null"
    }

    private static func nullableJSONStringValue(_ value: String) throws -> String? {
        guard let data = value.data(using: .utf8) else { return nil }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if decoded is NSNull { return nil }
        return decoded as? String
    }

    private static func reboundJSON(_ value: String, projectID: String, libraryID: String) throws -> String {
        guard var object = try jsonObject(value) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "项目数据 JSON 必须是对象")
        }
        object["projectId"] = projectID
        object["libraryId"] = libraryID
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw transferError("INVALID_PROJECT_PACKAGE", "无法重绑定项目 JSON")
        }
        return string
    }

    private static func transferError(_ code: String, _ message: String) -> SlateSyncError {
        SlateSyncError(code: code, message: message)
    }
}
