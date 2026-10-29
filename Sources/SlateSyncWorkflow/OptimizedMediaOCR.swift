import Foundation
import SlateSyncDomain
import SlateSyncMedia

struct OptimizedMediaOCRResult: Sendable {
    let document: PreparedDocument
    let outcome: OCROutcome
    let source: RecognitionPageSource
    let structures: [Int: RecognitionTableStructure]
    let fullMappings: [Int: RecognitionViewMapping]
    let diagnostics: [String]
}

/// Page-local staging bounds lossless bytes and decoded rasters. Full OCR is
/// consumed before planning details; the same full view is never inferred twice.
enum OptimizedMediaOCR {
    static func run(source: RecognitionPageSource, ocr: LocalOCRService, policy: RecognitionOptimizationPolicy,
                    includesDetails: Bool, session: String, cacheEnabled: Bool,
                    operation: MediaOperation, progress: MediaProgressSink?) async throws -> OptimizedMediaOCRResult {
        let supportsLossless = await ocr.supportsLosslessInput
        let lossless = policy.losslessLocalOCR && supportsLossless
        let slots = includesDetails ? 3 : 1
        let deadline = await ocr.deadline(views: source.pageCount * slots)
        var pages: [PreparedMediaPage] = [], observations: [OCRPageEvidence] = []
        var structures: [Int: RecognitionTableStructure] = [:]
        var mappings: [Int: RecognitionViewMapping] = [:]
        var diagnostics: [String] = []
        if policy.losslessLocalOCR && !lossless { diagnostics.append("当前 OCR 引擎使用兼容 JPEG 输入，未使用无损路径。") }
        var allCached = true, engine: OCREngineID?, model = "", ocrDuration = 0
        var optionalFailure: OCROutcome?
        for number in 1...source.pageCount {
            try operation.check()
            let base = try await source.compatibleViews(pageNumber: number, includesDetails: false,
                                                        lossless: lossless, operation: operation)
            guard let full = base.first else { throw MediaFailure.invalidInput }
            mappings[number] = full.mapping
            let fullDocument = document(filename: source.filename, images: base)
            let fullOutcome: OCROutcome
            if let optionalFailure { fullOutcome = optionalFailure }
            else {
                fullOutcome = try await ocr.recognize(fullDocument, session: session, cacheEnabled: cacheEnabled,
                    operation: operation, localImages: lossless ? [base.map(\.localOCR)] : nil,
                    deadline: deadline, allowsEmptyResult: true)
            }
            let fullEvidence = fullOutcome.result?.pages.first?.views.first
            if case .degraded(_, let warning) = fullOutcome {
                diagnostics.append("第 \(number) 页：\(warning)")
                // An optional engine failure does not trigger another identical
                // attempt in the detail phase or reset the cumulative budget.
                optionalFailure = fullOutcome
            }
            progress?(.init(stage: "ocr-full", completed: (number - 1) * slots + 1, total: source.pageCount * slots))
            if let fullEvidence, !fullEvidence.blocks.isEmpty,
               policy.dynamicCrops || policy.structureEvidence || policy.targetedReview {
                let geometry = try await source.tableGeometry(pageNumber: number, operation: operation)
                structures[number] = try RecognitionLayoutPlanner.plan(full: fullEvidence, mapping: full.mapping, geometry: geometry)
            }
            var views = base
            if includesDetails {
                if policy.dynamicCrops, let regions = structures[number]?.detailRegions, !regions.isEmpty {
                    // Keep the historical full view byte-for-byte. Re-rendered
                    // details use original page coordinates and actual crop maps.
                    let generated = try await source.views(pageNumber: number, regions: regions,
                        lossless: lossless, includesFullView: false, operation: operation)
                    views += generated
                } else {
                    let compatible = try await source.compatibleViews(pageNumber: number, includesDetails: true,
                                                                     lossless: lossless, operation: operation)
                    views += compatible.dropFirst()
                    if policy.dynamicCrops { diagnostics.append("第 \(number) 页未采用动态裁图：" + (structures[number]?.warnings.first ?? "布局证据不足。")) }
                }
            }
            var evidence = [fullEvidence ?? emptyEvidence(full.image, index: 0)]
            var outcomes = [fullOutcome]
            let details = Array(views.dropFirst())
            if !details.isEmpty, fullOutcome.result != nil {
                let detailOutcome = try await ocr.recognize(document(filename: source.filename, images: details),
                    session: session, cacheEnabled: cacheEnabled, operation: operation,
                    localImages: lossless ? [details.map(\.localOCR)] : nil, deadline: deadline, allowsEmptyResult: true)
                outcomes.append(detailOutcome)
                if case .degraded(_, let warning) = detailOutcome {
                    diagnostics.append("第 \(number) 页局部 OCR：\(warning)")
                    optionalFailure = detailOutcome
                }
                for (index, detail) in details.enumerated() {
                    let observedViews = detailOutcome.result?.pages.first?.views ?? []
                    let observed = observedViews.indices.contains(index) ? observedViews[index] : nil
                    evidence.append(.init(viewIndex: index + 1, viewType: .coreDetail,
                        width: detail.image.width, height: detail.image.height, durationMs: observed?.durationMs ?? 0,
                        truncated: observed?.truncated ?? false, blocks: observed?.blocks ?? []))
                }
            } else {
                evidence += details.enumerated().map { emptyEvidence($0.element.image, index: $0.offset + 1) }
            }
            for outcome in outcomes {
                if case .used(let result, let cached) = outcome {
                    engine = result.engine; model = result.modelVersion; ocrDuration += result.durationMs
                    allCached = allCached && cached
                } else { allCached = false }
            }
            pages.append(.init(pageNumber: number, views: views.enumerated().map {
                .init(viewIndex: $0.offset, viewType: $0.offset == 0 ? .full : .coreDetail, image: $0.element.image)
            }))
            observations.append(.init(pageNumber: number, views: evidence))
            progress?(.init(stage: "ocr-page", completed: number * slots, total: source.pageCount * slots))
        }
        try operation.check()
        let outcome: OCROutcome
        let selection = await ocr.selection
        if let engine, observations.contains(where: { $0.views.contains(where: { !$0.blocks.isEmpty }) }) {
            outcome = .used(.init(engine: engine, modelVersion: model, pages: observations, durationMs: ocrDuration), cacheHit: allCached)
        } else if selection.id == nil { outcome = .disabled }
        else if selection.required { throw SlateSyncError(code: "OCR_REQUIRED", message: "必需的本地 OCR 未产生有效证据", retryable: true) }
        else { outcome = .degraded(engine: selection.id, warning: "本地 OCR 未产生有效证据，将使用页面图片继续识别。") }
        return .init(document: .init(filename: source.filename, pages: pages), outcome: outcome, source: source,
                     structures: structures, fullMappings: mappings, diagnostics: diagnostics)
    }

    private static func document(filename: String, images: [RecognitionImageView]) -> PreparedDocument {
        .init(filename: filename, pages: [.init(pageNumber: 1, views: images.enumerated().map {
            .init(viewIndex: $0.offset, viewType: $0.offset == 0 ? .full : .coreDetail, image: $0.element.image)
        })])
    }
    private static func emptyEvidence(_ image: PreparedImage, index: Int) -> OCRViewEvidence {
        .init(viewIndex: index, viewType: index == 0 ? .full : .coreDetail, width: image.width, height: image.height, blocks: [])
    }
}
