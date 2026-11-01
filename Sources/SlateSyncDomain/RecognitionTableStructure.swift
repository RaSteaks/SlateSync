import Foundation

/// Line geometry is measured from page pixels, not OCR confidence. Coordinates
/// use the displayed source page before margin removal.
public struct TableRule: Codable, Hashable, Sendable {
    public enum Axis: String, Codable, Sendable { case horizontal, vertical }
    public let axis: Axis
    public let position: Double
    public let start: Double
    public let end: Double
    public init(axis: Axis, position: Double, start: Double, end: Double) {
        self.axis = axis; self.position = position; self.start = start; self.end = end
    }
}

public struct TablePageGeometry: Codable, Hashable, Sendable {
    public let rules: [TableRule]
    public let sampleWidth: Int
    public let sampleHeight: Int
    public init(rules: [TableRule], sampleWidth: Int, sampleHeight: Int) {
        self.rules = rules; self.sampleWidth = sampleWidth; self.sampleHeight = sampleHeight
    }
}

/// Runtime evidence only: none of these observations become authoritative
/// field values or persisted template rules automatically.
public struct RecognitionTableStructure: Codable, Hashable, Sendable {
    public struct Column: Codable, Hashable, Sendable {
        public let region: PageRegion
        public let field: String?
        public let camera: String?
        public init(region: PageRegion, field: String?, camera: String?) {
            self.region = region; self.field = field; self.camera = camera
        }
    }
    public struct Witness: Codable, Hashable, Sendable {
        public let index: Int
        public let text: String
        public let confidence: Double
        public let region: PageRegion
        public init(index: Int, text: String, confidence: Double, region: PageRegion) {
            self.index = index; self.text = text; self.confidence = confidence; self.region = region
        }
    }
    public struct Cell: Codable, Hashable, Sendable {
        public let column: Int
        public let firstRow: Int
        public let rowSpan: Int
        public let region: PageRegion
        public let witnesses: [Int]
        public init(column: Int, firstRow: Int, rowSpan: Int, region: PageRegion, witnesses: [Int]) {
            self.column = column; self.firstRow = firstRow; self.rowSpan = rowSpan
            self.region = region; self.witnesses = witnesses
        }
    }
    public let region: PageRegion?
    public let columns: [Column]
    public let rows: [PageRegion]
    public let cells: [Cell]
    public let witnesses: [Witness]
    public let unassigned: [Int]
    public let detailRegions: [PageRegion]
    public let warnings: [String]

    public init(region: PageRegion?, columns: [Column], rows: [PageRegion], cells: [Cell],
                witnesses: [Witness], unassigned: [Int], detailRegions: [PageRegion], warnings: [String]) {
        self.region = region; self.columns = columns; self.rows = rows; self.cells = cells
        self.witnesses = witnesses; self.unassigned = unassigned; self.detailRegions = detailRegions; self.warnings = warnings
    }
}
