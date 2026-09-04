import Foundation

/// One immutable set of recognized slate fields consumed by Resolve export.
/// The export layer deliberately ignores free-form OCR comments when deriving
/// Resolve's strict take-status marker.
public struct ResolveSlateRecord: Codable, Hashable, Sendable {
    public var cardNumber: String?
    public var videoCode: String?
    public var scene: String?
    public var shot: String?
    public var take: String?
    public var takeStatus: TakeStatus?
    public var goodTake: Bool?
    public var comments: String?
    public var reviewRequiredFields: [String]

    public init(
        cardNumber: String? = nil,
        videoCode: String? = nil,
        scene: String? = nil,
        shot: String? = nil,
        take: String? = nil,
        takeStatus: TakeStatus? = nil,
        goodTake: Bool? = nil,
        comments: String? = nil,
        reviewRequiredFields: [String] = []
    ) {
        self.cardNumber = cardNumber
        self.videoCode = videoCode
        self.scene = scene
        self.shot = shot
        self.take = take
        self.takeStatus = takeStatus
        self.goodTake = goodTake
        self.comments = comments
        self.reviewRequiredFields = reviewRequiredFields
    }
}

/// One user-authored CSV cell replacement. The array containing these values
/// is ordered because Electron applies `csvEdits` in request order.
public struct ResolveSparseEdit: Codable, Hashable, Sendable {
    public let rowIndex: Int
    public let columnIndex: Int
    public let value: String

    public init(rowIndex: Int, columnIndex: Int, value: String) {
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.value = value
    }
}

public struct ResolveCSVChange: Codable, Hashable, Sendable {
    public let rowIndex: Int
    public let field: String
    public let header: String
    public let previous: String
    public let next: String

    public init(rowIndex: Int, field: String, header: String, previous: String, next: String) {
        self.rowIndex = rowIndex
        self.field = field
        self.header = header
        self.previous = previous
        self.next = next
    }
}

public struct ResolveRecordStatus: Codable, Hashable, Sendable {
    public let recordIndex: Int
    public let status: String
    public let fileName: String?
    public let fileNames: [String]?
    public let rowIndexes: [Int]?
    public let matchedRows: Int?
    public let missingFields: [String]?

    public init(
        recordIndex: Int,
        status: String,
        fileName: String? = nil,
        fileNames: [String]? = nil,
        rowIndexes: [Int]? = nil,
        matchedRows: Int? = nil,
        missingFields: [String]? = nil
    ) {
        self.recordIndex = recordIndex
        self.status = status
        self.fileName = fileName
        self.fileNames = fileNames
        self.rowIndexes = rowIndexes
        self.matchedRows = matchedRows
        self.missingFields = missingFields
    }
}

public struct ResolveMergeResult: Codable, Hashable, Sendable {
    public let table: ResolveCSVTable
    public let statuses: [ResolveRecordStatus?]
    public let warnings: [String]
    public let addedColumns: [String]
    public let matchedRecordCount: Int
    public let cameraFpsMatchedMaterialCount: Int
    public let cameraFpsMatchedRowCount: Int
    public let shootDayMatchedMaterialCount: Int
    public let shootDayMatchedRowCount: Int
    public let updatedRowCount: Int
    public let changedCellCount: Int
    public let overwrittenCellCount: Int
    public let changes: [ResolveCSVChange]
    public let expectedMaterialCount: Int
    public let recognizedMaterialCount: Int
    public let unrecognizedMaterials: [String]
    public let unrecognizedRowIndexes: [Int]
    public let rowKeys: [String]
    public let missingCameraFPSKeys: [String]
    public let missingShootDayKeys: [String]
    public let sequenceAnomalies: [SlateSequenceAnomaly]

    public init(
        table: ResolveCSVTable,
        statuses: [ResolveRecordStatus?],
        warnings: [String],
        addedColumns: [String],
        matchedRecordCount: Int,
        cameraFpsMatchedMaterialCount: Int,
        cameraFpsMatchedRowCount: Int,
        shootDayMatchedMaterialCount: Int,
        shootDayMatchedRowCount: Int,
        updatedRowCount: Int,
        changes: [ResolveCSVChange],
        expectedMaterialCount: Int,
        recognizedMaterialCount: Int,
        unrecognizedMaterials: [String],
        unrecognizedRowIndexes: [Int],
        rowKeys: [String],
        missingCameraFPSKeys: [String] = [],
        missingShootDayKeys: [String] = [],
        sequenceAnomalies: [SlateSequenceAnomaly] = []
    ) {
        self.table = table
        self.statuses = statuses
        self.warnings = warnings
        self.addedColumns = addedColumns
        self.matchedRecordCount = matchedRecordCount
        self.cameraFpsMatchedMaterialCount = cameraFpsMatchedMaterialCount
        self.cameraFpsMatchedRowCount = cameraFpsMatchedRowCount
        self.shootDayMatchedMaterialCount = shootDayMatchedMaterialCount
        self.shootDayMatchedRowCount = shootDayMatchedRowCount
        self.updatedRowCount = updatedRowCount
        changedCellCount = changes.count
        overwrittenCellCount = changes.filter { !$0.previous.isEmpty }.count
        self.changes = changes
        self.expectedMaterialCount = expectedMaterialCount
        self.recognizedMaterialCount = recognizedMaterialCount
        self.unrecognizedMaterials = unrecognizedMaterials
        self.unrecognizedRowIndexes = unrecognizedRowIndexes
        self.rowKeys = rowKeys
        self.missingCameraFPSKeys = missingCameraFPSKeys
        self.missingShootDayKeys = missingShootDayKeys
        self.sequenceAnomalies = sequenceAnomalies
    }
}

/// Immutable end-to-end Resolve export artifact. Duration is safe diagnostic
/// metadata; no CSV cell content or source path is included in it.
public struct ResolveExportArtifact: Codable, Hashable, Sendable {
    public let merge: ResolveMergeResult
    public let data: Data
    public let durationMilliseconds: Int

    public init(merge: ResolveMergeResult, data: Data, durationMilliseconds: Int) {
        self.merge = merge
        self.data = data
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct SlateSequenceAnomaly: Codable, Hashable, Sendable {
    public let key: String
    public let type: String
    public let message: String

    public init(key: String, type: String, message: String) {
        self.key = key
        self.type = type
        self.message = message
    }
}

public enum MetadataNameTemplate: Codable, Hashable, Sendable {
    case dirnameSuffix(String)
    case fixedName(String)
}

public struct SlateMetadataScanOptions: Codable, Hashable, Sendable {
    public var expectedKeys: [String]
    public var maxDepth: Int
    public var maxFileBytes: Int

    public init(expectedKeys: [String], maxDepth: Int = 4, maxFileBytes: Int = 2 * 1024 * 1024) {
        self.expectedKeys = expectedKeys
        self.maxDepth = (1...12).contains(maxDepth) ? maxDepth : 4
        self.maxFileBytes = (1...(100 * 1024 * 1024)).contains(maxFileBytes)
            ? maxFileBytes
            : 2 * 1024 * 1024
    }
}

public struct ScenarioOCRBlock: Codable, Hashable, Sendable {
    public let text: String
    public let confidence: Double
    public let bboxNormalized: [Double]

    public init(text: String, confidence: Double, bboxNormalized: [Double]) {
        self.text = text
        self.confidence = confidence
        self.bboxNormalized = bboxNormalized
    }
}

public struct ScenarioOCRView: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let blocks: [ScenarioOCRBlock]

    public init(width: Int, height: Int, blocks: [ScenarioOCRBlock]) {
        self.width = width
        self.height = height
        self.blocks = blocks
    }
}

public struct ScenarioOCRPage: Codable, Hashable, Sendable {
    public let pageNumber: Int
    public let views: [ScenarioOCRView]

    public init(pageNumber: Int, views: [ScenarioOCRView]) {
        self.pageNumber = pageNumber
        self.views = views
    }
}

public struct ScenarioObservationInput: Codable, Hashable, Sendable {
    public let filename: String
    public let ocrEngine: String?
    public let ocrUsed: Bool
    public let pages: [ScenarioOCRPage]

    public init(filename: String, ocrEngine: String? = nil, ocrUsed: Bool = false, pages: [ScenarioOCRPage]) {
        self.filename = filename
        self.ocrEngine = ocrEngine
        self.ocrUsed = ocrUsed
        self.pages = pages
    }
}

public struct ScenarioMatchResult: Codable, Hashable, Sendable {
    public let profile: ScenarioData
    public let observationId: String
    public let match: String
    public let score: Double
    public let ambiguous: Bool

    public init(profile: ScenarioData, observationId: String, match: String, score: Double, ambiguous: Bool) {
        self.profile = profile
        self.observationId = observationId
        self.match = match
        self.score = score
        self.ambiguous = ambiguous
    }
}

/// Project-scoped persistence result returned after the profile usage update
/// and its observation row commit together in the frozen v1 transaction.
public struct ScenarioMatchCommit: Codable, Hashable, Sendable {
    public let profile: ScenarioData
    public let observationID: String

    public init(profile: ScenarioData, observationID: String) {
        self.profile = profile
        self.observationID = observationID
    }
}
