import Foundation
import SlateSyncDomain

/// Owns bounded page fan-out and deterministic input-order reassembly. High
/// accuracy adds audit/review stages without changing the page ownership unit.
public struct RecognitionPagePipeline: Sendable {
    public typealias ProgressSink = @Sendable (RecognitionProgress) -> Void

    public struct Output: Sendable {
        public let result: RecognitionSheet
        public let usage: TokenUsage?
        public let stageCount: Int
        public let pages: [PageOutput]
    }

    public struct PageOutput: Sendable {
        public let pageNumber: Int
        public let result: RecognitionSheet
        public let responses: [RecognitionStageResponse]
    }

    private let client: ProviderRecognitionClient

    public init(client: ProviderRecognitionClient) { self.client = client }

    public func run(
        pages: [RecognitionPageInput],
        provider: ProviderDescriptor,
        model: ResolvedModel,
        accuracy: ProjectSettings.AccuracyMode,
        formats: ResolveFieldFormats,
        prompts: (primary: String, audit: String, review: String),
        pageConcurrency: Int = 2,
        timeoutMilliseconds: Int = 180_000,
        maximumTimeoutRetries: Int = 1,
        filename: String,
        progress: ProgressSink? = nil
    ) async throws -> Output {
        guard !pages.isEmpty, pages.count <= 20, pages.allSatisfy({ !$0.views.isEmpty && $0.views.count <= 3 }) else { throw RecognitionFailure.invalidInput }
        let limit = min(6, max(1, pageConcurrency))
        var outputs = Array<PageOutput?>(repeating: nil, count: pages.count)
        var next = 0, completed = 0
        do {
            try await withThrowingTaskGroup(of: (Int, PageOutput).self) { group in
                func enqueue() {
                    guard next < pages.count else { return }
                    let index = next, page = pages[index], completedSnapshot = completed; next += 1
                    group.addTask {
                        let result = try await recognizePage(
                            page, count: pages.count, provider: provider, model: model,
                            accuracy: accuracy, prompts: prompts,
                            timeoutMilliseconds: timeoutMilliseconds,
                            maximumTimeoutRetries: maximumTimeoutRetries,
                            filename: filename, client: client, progress: progress,
                            completedBeforePage: completedSnapshot
                        )
                        return (index, result)
                    }
                }
                for _ in 0..<min(limit, pages.count) { enqueue() }
                while let (index, result) = try await group.next() {
                    outputs[index] = result; completed += 1
                    let percent = Int((35 + Double(completed) / Double(pages.count) * 60).rounded())
                    progress?(.init(phase: "page-complete", completed: completed, total: pages.count, message: "已完成第 \(result.pageNumber) 页（\(completed)/\(pages.count) 页）", percent: percent, pageNumber: result.pageNumber))
                    enqueue()
                }
            }
        } catch is CancellationError { throw RecognitionFailure.canceled }
        catch let error as SlateSyncError { throw error }
        let pagesOut = outputs.compactMap { $0 }
        let merged = RecognitionPostprocessor.mergePages(pagesOut.map { ($0.pageNumber, $0.result) }, accuracy: accuracy, formats: formats)
        let responses = pagesOut.flatMap(\.responses)
        return Output(result: merged, usage: RecognitionNormalizer.aggregateUsage(responses.map(\.usage)), stageCount: responses.count, pages: pagesOut)
    }

    private func recognizePage(
        _ page: RecognitionPageInput,
        count: Int,
        provider: ProviderDescriptor,
        model: ResolvedModel,
        accuracy: ProjectSettings.AccuracyMode,
        prompts: (primary: String, audit: String, review: String),
        timeoutMilliseconds: Int,
        maximumTimeoutRetries: Int,
        filename: String,
        client: ProviderRecognitionClient,
        progress: ProgressSink?,
        completedBeforePage: Int
    ) async throws -> PageOutput {
        let pageName = "\(filename) · 第 \(page.pageNumber)/\(count) 页"
        let percent = Int((35 + Double(completedBeforePage) / Double(count) * 60).rounded())
        do {
            progress?(.init(phase: "primary", completed: completedBeforePage, total: count, message: "正在主识别第 \(page.pageNumber)/\(count) 页", percent: percent, pageNumber: page.pageNumber))
            let primaryRequest = request(page: page, stage: .primary, images: page.views.map(\.image), provider: provider, model: model, filename: pageName, prompt: prompts.primary, instruction: page.fullOCREvidence, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries)
            if accuracy == .standard {
                let response = try await client.recognize(primaryRequest)
                let sheet = try RecognitionNormalizer.normalize(try ProviderRecognitionClient.structuredJSON(from: response.text), pageNumber: page.pageNumber)
                return .init(pageNumber: page.pageNumber, result: sheet, responses: [response])
            }

            progress?(.init(phase: "audit", completed: completedBeforePage, total: count, message: "正在独立查漏第 \(page.pageNumber)/\(count) 页", percent: percent, pageNumber: page.pageNumber))
            let coreImages = page.views.count > 1 ? Array(page.views.dropFirst().map(\.image)) : [page.views[0].image]
            let auditRequest = request(page: page, stage: .audit, images: coreImages, provider: provider, model: model, filename: pageName + " · 核心字段查漏", prompt: prompts.audit, instruction: page.coreOCREvidence, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries)
            async let primaryResponse = client.recognize(primaryRequest)
            async let auditResponse = client.recognize(auditRequest)
            let (first, second) = try await (primaryResponse, auditResponse)
            let primary = try RecognitionNormalizer.normalize(try ProviderRecognitionClient.structuredJSON(from: first.text), pageNumber: page.pageNumber)
            let audit = try RecognitionNormalizer.normalize(try ProviderRecognitionClient.structuredJSON(from: second.text), pageNumber: page.pageNumber)
            let combined = RecognitionPostprocessor.mergeHighAccuracy(primary, audit)
            guard !combined.conflicts.isEmpty || !combined.auditOnlyKeys.isEmpty else {
                return .init(pageNumber: page.pageNumber, result: combined.result, responses: [first, second])
            }

            let targets = combined.conflicts.map { conflict in
                "\(conflict.key)（两次识别冲突；冲突字段：\(conflict.fields.joined(separator: "、"))）"
            } + combined.auditOnlyKeys.map { "\($0)（仅核心查漏发现；请先确认图中确实存在此素材）" }
            progress?(.init(phase: "review", completed: completedBeforePage, total: count, message: "正在复核第 \(page.pageNumber) 页的 \(targets.count) 个冲突或查漏候选", percent: percent, pageNumber: page.pageNumber))
            let reviewInstruction = "只复核以下 \(targets.count) 个素材键；图中找不到的键不要输出：\n" + targets.joined(separator: "\n") + evidenceSuffix(page.coreOCREvidence)
            let reviewRequest = request(page: page, stage: .review, images: coreImages, provider: provider, model: model, filename: pageName + " · 冲突复核", prompt: prompts.review, instruction: reviewInstruction, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries)
            let third = try await client.recognize(reviewRequest)
            let review = try RecognitionNormalizer.normalize(try ProviderRecognitionClient.structuredJSON(from: third.text), pageNumber: page.pageNumber)
            return .init(pageNumber: page.pageNumber, result: RecognitionPostprocessor.applyReview(combined, review: review), responses: [first, second, third])
        } catch is CancellationError { throw RecognitionFailure.canceled }
        catch let error as SlateSyncError { throw RecognitionFailure.page(error, page: page.pageNumber, count: count) }
        catch { throw RecognitionFailure.page(error, page: page.pageNumber, count: count) }
    }

    private func request(page: RecognitionPageInput, stage: RecognitionStage, images: [PreparedImage], provider: ProviderDescriptor, model: ResolvedModel, filename: String, prompt: String, instruction: String, timeout: Int, retries: Int) -> RecognitionStageRequest {
        .init(provider: provider, model: model, stage: stage, filename: filename, images: images, systemPrompt: prompt, userInstruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instruction, schema: stage == .primary ? RecognitionSchemas.full : RecognitionSchemas.core, timeoutMilliseconds: timeout, maximumTimeoutRetries: retries)
    }

    private func evidenceSuffix(_ evidence: String) -> String {
        let value = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : "\n\n" + value
    }
}
