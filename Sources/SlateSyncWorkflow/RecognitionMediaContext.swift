import Foundation
import SlateSyncDomain
import SlateSyncMedia

/// Kept only for the active recognition request. Source bytes and geometry do
/// not change saved task schemas or become learned template observations.
public struct RecognitionMediaContext: Sendable {
    public let policy: RecognitionOptimizationPolicy
    public let source: RecognitionPageSource?
    public let structures: [Int: RecognitionTableStructure]
    public let fullMappings: [Int: RecognitionViewMapping]
    public let diagnostics: [String]

    public var identity: String {
        "structure-v\(RecognitionOptimizationPolicy.version):\(policy.dynamicCrops):\(policy.structureEvidence):\(policy.losslessLocalOCR):\(policy.targetedReview):\(source?.digest ?? "restored")"
    }

    public func instruction(pageNumber: Int) -> String {
        guard policy.structureEvidence, let structure = structures[pageNumber],
              let mapping = fullMappings[pageNumber] else { return "" }
        return RecognitionStructureEvidence.format(structure, fullMapping: mapping)
    }

    public func reviewProvider(page: PreparedMediaPage, fullEvidence: OCRViewEvidence?,
                               originalEvidence: String) -> RecognitionPageInput.ReviewImageProvider? {
        guard policy.targetedReview else { return nil }
        return { records in
            let original = page.views.map(\.image)
            guard let source, let structure = structures[page.pageNumber],
                  let full = original.first,
                  let regions = try RecognitionReviewPlanner.regions(for: records, structure: structure) else {
                return .init(images: original, evidence: originalEvidence,
                    warning: "冲突位置或卷号归属不明确，沿用完整参照与原局部图复核。")
            }
            let operation = MediaOperation()
            return try await withTaskCancellationHandler {
                do {
                    let generated = try await source.views(pageNumber: page.pageNumber, regions: regions,
                        includesFullView: false, operation: operation)
                    try operation.check()
                    // Existing detail OCR coordinates refer to different crops.
                    // Only the unchanged full view's evidence survives recropping.
                    let evidence = fullEvidence.map {
                        OCREvidenceFormatter.format(.init(pageNumber: page.pageNumber, views: [$0]), core: true)
                    } ?? ""
                    return .init(images: [full] + generated.map(\.image), evidence: evidence)
                } catch {
                    if operation.isCanceled || MediaFailure.isTerminal(error) { throw error }
                    return .init(images: original, evidence: originalEvidence,
                        warning: "无法生成冲突区域图，沿用原视图复核。")
                }
            } onCancel: { operation.cancel() }
        }
    }
}
