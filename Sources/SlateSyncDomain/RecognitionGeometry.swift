import Foundation

/// A nonempty rectangle in top-left, normalized coordinates. Validation belongs
/// here so geometry consumers never silently clamp an invalid model/OCR box.
public struct PageRegion: Codable, Hashable, Sendable {
    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) throws {
        guard [left, top, right, bottom].allSatisfy(\.isFinite),
              left >= 0, top >= 0, right <= 1, bottom <= 1,
              left < right, top < bottom else { throw MediaFailure.invalidInput }
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }

    private init() { left = 0; top = 0; right = 1; bottom = 1 }
    public static let full = PageRegion()
    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var coordinates: [Double] { [left, top, right, bottom] }

    public func contains(_ other: Self) -> Bool {
        other.left >= left && other.top >= top && other.right <= right && other.bottom <= bottom
    }

    public func intersection(_ other: Self) -> Self? {
        try? .init(left: max(left, other.left), top: max(top, other.top),
                   right: min(right, other.right), bottom: min(bottom, other.bottom))
    }

    public func union(_ other: Self) -> Self {
        // Both operands already satisfy the unit-square boundary.
        Self(uncheckedLeft: min(left, other.left), top: min(top, other.top),
             right: max(right, other.right), bottom: max(bottom, other.bottom))
    }

    private init(uncheckedLeft left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }

    private enum CodingKeys: String, CodingKey { case left, top, right, bottom }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(left: container.decode(Double.self, forKey: .left),
                      top: container.decode(Double.self, forKey: .top),
                      right: container.decode(Double.self, forKey: .right),
                      bottom: container.decode(Double.self, forKey: .bottom))
    }
}

/// Each piece maps a continuous part of a view back to the displayed page
/// before blank-margin removal. Header/body composites require separate pieces.
public struct RecognitionViewMapping: Codable, Hashable, Sendable {
    public struct Piece: Codable, Hashable, Sendable {
        public let view: PageRegion
        public let page: PageRegion
        public init(view: PageRegion, page: PageRegion) {
            self.view = view; self.page = page
        }
    }

    public let pieces: [Piece]
    public init(pieces: [Piece]) { self.pieces = pieces }
    public init(page: PageRegion) { pieces = [.init(view: .full, page: page)] }

    public func pageRegion(for region: PageRegion) -> PageRegion? {
        let owners = pieces.filter { $0.view.contains(region) }
        // A box crossing a stitched boundary, or belonging to overlapping
        // pieces, has no unambiguous rectangular source and remains unassigned.
        guard owners.count == 1, let piece = owners.first else { return nil }
        return Self.convert(region, from: piece.view, to: piece.page)
    }

    public func viewRegion(for region: PageRegion) -> PageRegion? {
        let owners = pieces.filter { $0.page.contains(region) }
        guard owners.count == 1, let piece = owners.first else { return nil }
        return Self.convert(region, from: piece.page, to: piece.view)
    }

    private static func convert(_ region: PageRegion, from source: PageRegion, to target: PageRegion) -> PageRegion? {
        // Clamp only floating-point roundoff after containment was established;
        // this is not a repair path for an out-of-bounds external rectangle.
        try? .init(
            left: max(target.left, target.left + (region.left - source.left) / source.width * target.width),
            top: max(target.top, target.top + (region.top - source.top) / source.height * target.height),
            right: min(target.right, target.left + (region.right - source.left) / source.width * target.width),
            bottom: min(target.bottom, target.top + (region.bottom - source.top) / source.height * target.height))
    }
}

/// Experimental strategies are explicit runtime inputs. They do not change
/// saved project settings or enable themselves before field evaluation.
public struct RecognitionOptimizationPolicy: Hashable, Sendable {
    public static let version = 1
    public let dynamicCrops: Bool
    public let structureEvidence: Bool
    public let losslessLocalOCR: Bool
    public let targetedReview: Bool
    public init(dynamicCrops: Bool = false, structureEvidence: Bool = false,
                losslessLocalOCR: Bool = false, targetedReview: Bool = false) {
        self.dynamicCrops = dynamicCrops; self.structureEvidence = structureEvidence
        self.losslessLocalOCR = losslessLocalOCR; self.targetedReview = targetedReview
    }
    public static let baseline = RecognitionOptimizationPolicy()
}

/// Local recognition can consume PNG without weakening PreparedImage's frozen
/// JPEG transport/storage contract. Bytes are decoded inside the media owner.
public struct LocalOCRImage: Hashable, Sendable {
    public enum Format: String, Codable, Sendable { case jpeg, png }
    public let bytes: Data
    public let format: Format
    public let width: Int
    public let height: Int
    public init(bytes: Data, format: Format, width: Int, height: Int) throws {
        guard width > 0, height > 0, max(width, height) <= 3000 else { throw MediaFailure.invalidInput }
        switch format {
        case .jpeg:
            guard bytes.count >= 4, bytes.starts(with: [0xff, 0xd8, 0xff]),
                  bytes.suffix(2) == Data([0xff, 0xd9]) else { throw MediaFailure.invalidInput }
        case .png:
            guard bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                throw MediaFailure.invalidInput
            }
        }
        self.bytes = bytes; self.format = format; self.width = width; self.height = height
    }

    /// Pairing is checked at public engine boundaries; JPEG coordinates remain
    /// valid only when the alternate encoding has exactly the same dimensions.
    public static func validate(_ images: [[Self]]?, document: PreparedDocument) throws {
        guard let images else { return }
        guard images.count == document.pages.count else { throw MediaFailure.invalidInput }
        for (images, page) in zip(images, document.pages) {
            guard images.count == page.views.count else { throw MediaFailure.invalidInput }
            for (image, view) in zip(images, page.views) {
                guard image.width == view.image.width, image.height == view.image.height else { throw MediaFailure.invalidInput }
            }
        }
    }
}
