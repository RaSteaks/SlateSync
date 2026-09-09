import Foundation
import SlateSyncDomain

/// Rebuilds prepared views from the data URLs persisted in v1 tasks. Every
/// entry is decoded and restored in order — original JPEG bytes, view order
/// and the position-derived view type survive a reopen; nothing is re-cropped
/// or re-compressed. Only tasks whose groups still hold a single historical
/// full image fall back to bounded re-preparation.
public enum PreparedDocumentRestore {
    public static let dataURLPrefix = "data:image/jpeg;base64,"

    /// True when every page group carries exactly one full image — the legacy
    /// task shape whose pages still restore through full preparation.
    public static func isLegacySingleView(_ groups: [[String]]) -> Bool {
        groups.allSatisfy { $0.count == 1 }
    }

    /// Decodes one persisted data URL; a corrupt payload fails closed here
    /// instead of silently shrinking the restored document.
    public static func jpegData(_ dataURL: String?) throws -> Data {
        guard let dataURL, dataURL.hasPrefix(dataURLPrefix),
              let data = Data(base64Encoded: String(dataURL.dropFirst(dataURLPrefix.count))) else {
            throw MediaFailure.invalidInput
        }
        return data
    }

    /// Restores one page group in view order. View type follows the frozen
    /// position contract (first view full, later views core-detail), and the
    /// dimensions come from the same bounded decode Vision uses so downstream
    /// pixel math sees the persisted geometry.
    public static func views(_ group: [String]) throws -> [PreparedMediaView] {
        guard !group.isEmpty else { throw MediaFailure.invalidInput }
        return try group.enumerated().map { index, dataURL in
            let jpeg = try jpegData(dataURL)
            let decoded = try autoreleasepool { try ImageRasterizer.decode(jpeg, maximum: 3000) }
            return .init(
                viewIndex: index,
                viewType: index == 0 ? .full : .coreDetail,
                image: try PreparedImage(jpeg: jpeg, width: decoded.width, height: decoded.height)
            )
        }
    }
}
