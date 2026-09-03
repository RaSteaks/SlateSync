import Foundation

public struct ResolveFieldFormats: Codable, Hashable, Sendable {
    public var scene: String
    public var shot: String
    public var take: String

    public init(scene: String = "XXX", shot: String = "XX", take: String = "XX") {
        self.scene = scene
        self.shot = shot
        self.take = take
    }
}
public struct ResolveComments: Codable, Hashable, Sendable {
    public var goodTake: String
    public var holdTake: String

    public init(goodTake: String = "_OK", holdTake: String = "_KP") {
        self.goodTake = goodTake
        self.holdTake = holdTake
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var version: Int
    public var providerId: String?
    public var modelId: String?
    public var accuracyMode: AccuracyMode
    public var scenarioId: String?
    public var customPrompt: String
    public var resolve: ResolveSettings

    public enum AccuracyMode: String, Codable, Sendable { case high, standard }

    public struct ResolveSettings: Codable, Hashable, Sendable {
        public var fieldFormats: ResolveFieldFormats
        public var comments: ResolveComments

        public init(
            fieldFormats: ResolveFieldFormats = .init(),
            comments: ResolveComments = .init()
        ) {
            self.fieldFormats = fieldFormats
            self.comments = comments
        }
    }

    public init(
        version: Int = 1,
        providerId: String? = nil,
        modelId: String? = nil,
        accuracyMode: AccuracyMode = .high,
        scenarioId: String? = nil,
        customPrompt: String = "",
        resolve: ResolveSettings = .init()
    ) {
        self.version = version
        self.providerId = providerId
        self.modelId = modelId
        self.accuracyMode = accuracyMode
        self.scenarioId = scenarioId
        self.customPrompt = customPrompt
        self.resolve = resolve
    }
}

public struct ProjectSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public let relativePath: String
    public var archivedAt: String?
    public let createdAt: String
    public var updatedAt: String
    public var taskCount: Int
    public var latestTaskAt: String?
    public var canArchive: Bool

    public init(
        id: String,
        name: String,
        description: String = "",
        relativePath: String,
        archivedAt: String? = nil,
        createdAt: String,
        updatedAt: String,
        taskCount: Int = 0,
        latestTaskAt: String? = nil,
        canArchive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.relativePath = relativePath
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.taskCount = taskCount
        self.latestTaskAt = latestTaskAt
        self.canArchive = canArchive
    }
}

public struct ProjectData: Codable, Hashable, Sendable {
    public var summary: ProjectSummary
    public var settings: ProjectSettings

    public init(summary: ProjectSummary, settings: ProjectSettings = .init()) {
        self.summary = summary
        self.settings = settings
    }
}

public struct LibraryInfo: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let formatVersion: Int
    public let path: String

    public init(id: String, name: String, formatVersion: Int = 1, path: String) {
        self.id = id
        self.name = name
        self.formatVersion = formatVersion
        self.path = path
    }
}
