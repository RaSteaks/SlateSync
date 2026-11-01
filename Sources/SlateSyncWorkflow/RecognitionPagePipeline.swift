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
        maximumRequestBytes: Int = 80 * 1024 * 1024,
        filename: String,
        progress: ProgressSink? = nil,
        candidates: [ProviderModelSelection] = [],
        registry: ProviderRegistry? = nil,
        failoverState: RecognitionFailoverState? = nil,
        recoveryCache: RecognitionRecoveryCache? = nil,
        recoveryID: String? = nil
    ) async throws -> Output {
        guard !pages.isEmpty, pages.count <= 20, pages.allSatisfy({ !$0.views.isEmpty && $0.views.count <= 3 }) else { throw RecognitionFailure.invalidInput }
        let recoveryKey = recoveryID.map {
            Self.recoveryKey(id: $0, pages: pages, provider: provider, model: model,
                accuracy: accuracy, formats: formats, prompts: prompts, maximumRequestBytes: maximumRequestBytes)
        }
        let limit = min(6, max(1, pageConcurrency))
        var outputs = Array<PageOutput?>(repeating: nil, count: pages.count)
        var next = 0, completed = 0
        do {
            try await withThrowingTaskGroup(of: (Int, PageOutput).self) { group in
                func enqueue() {
                    guard next < pages.count else { return }
                    let index = next, page = pages[index], completedSnapshot = completed; next += 1
                    group.addTask {
                        if let recoveryCache, let recoveryKey,
                           let cached = await recoveryCache.result(key: recoveryKey, pageNumber: page.pageNumber) {
                            return (index, cached)
                        }
                        let result: PageOutput
                        if let registry, let failoverState, !candidates.isEmpty {
                            result = try await recognizePageWithFailover(
                                page, count: pages.count, candidates: candidates,
                                registry: registry, state: failoverState,
                                accuracy: accuracy, prompts: prompts,
                                timeoutMilliseconds: timeoutMilliseconds,
                                maximumTimeoutRetries: maximumTimeoutRetries,
                                maximumRequestBytes: maximumRequestBytes,
                                filename: filename, client: client, progress: progress,
                                completedBeforePage: completedSnapshot
                            )
                        } else {
                            result = try await recognizePageAttempt(
                                page, count: pages.count, provider: provider, model: model,
                                accuracy: accuracy, prompts: prompts,
                                timeoutMilliseconds: timeoutMilliseconds,
                                maximumTimeoutRetries: maximumTimeoutRetries,
                                maximumRequestBytes: maximumRequestBytes,
                                filename: filename, client: client, progress: progress,
                                completedBeforePage: completedSnapshot
                            )
                        }
                        try Task.checkCancellation()
                        if let recoveryCache, let recoveryKey {
                            await recoveryCache.store(result, key: recoveryKey)
                        }
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
        if let recoveryCache, let recoveryKey { await recoveryCache.clear(key: recoveryKey) }
        return Output(result: merged, usage: RecognitionNormalizer.aggregateUsage(responses.map(\.usage)), stageCount: responses.count, pages: pagesOut)
    }

    private static func recoveryKey(
        id: String, pages: [RecognitionPageInput], provider: ProviderDescriptor,
        model: ResolvedModel, accuracy: ProjectSettings.AccuracyMode,
        formats: ResolveFieldFormats,
        prompts: (primary: String, audit: String, review: String), maximumRequestBytes: Int
    ) -> String {
        var hash = Hasher()
        hash.combine(id)
        hash.combine(provider.id)
        hash.combine(provider.baseURL)
        hash.combine(provider.revision)
        hash.combine(model.apiID)
        hash.combine(model.jsonMode)
        hash.combine(accuracy)
        hash.combine(formats)
        hash.combine(prompts.primary)
        hash.combine(prompts.audit)
        hash.combine(prompts.review)
        hash.combine(maximumRequestBytes)
        for page in pages {
            hash.combine(page.pageNumber)
            hash.combine(page.fullOCREvidence)
            hash.combine(page.coreOCREvidence)
            hash.combine(page.scenarioInstruction)
            hash.combine(page.layoutInstruction)
            hash.combine(page.optimizationIdentity)
            for view in page.views { hash.combine(view.image) }
        }
        return String(hash.finalize())
    }

    private func recognizePageWithFailover(
        _ page: RecognitionPageInput,
        count: Int,
        candidates: [ProviderModelSelection],
        registry: ProviderRegistry,
        state: RecognitionFailoverState,
        accuracy: ProjectSettings.AccuracyMode,
        prompts: (primary: String, audit: String, review: String),
        timeoutMilliseconds: Int,
        maximumTimeoutRetries: Int,
        maximumRequestBytes: Int,
        filename: String,
        client: ProviderRecognitionClient,
        progress: ProgressSink?,
        completedBeforePage: Int
    ) async throws -> PageOutput {
        var attempted = Set<ProviderModelSelection>()
        var lastError: SlateSyncError?
        for candidate in candidates {
            try Task.checkCancellation()
            guard !attempted.contains(candidate),
                  await state.isAvailable(candidate.providerID) else { continue }
            attempted.insert(candidate)
            let provider: ProviderDescriptor
            let model: ResolvedModel
            do {
                provider = try await registry.descriptor(providerID: candidate.providerID)
                model = try await registry.resolveModel(providerID: candidate.providerID, modelID: candidate.modelID)
                // A backup must be confirmed under its current configuration.
                // The primary retains the pre-feature built-in compatibility
                // path for existing task and project selections.
                if candidate != candidates[0], model.capabilityStatus != .verified { continue }
            } catch {
                if candidate == candidates[0] { throw error }
                continue
            }
            if candidate != candidates[0] {
                progress?(.init(phase: "failover", completed: completedBeforePage, total: count,
                    message: "正在切换备用服务并重试第 \(page.pageNumber) 页", pageNumber: page.pageNumber))
            }
            do {
                let result = try await recognizePageAttempt(
                    page, count: count, provider: provider, model: model,
                    accuracy: accuracy, prompts: prompts,
                    timeoutMilliseconds: timeoutMilliseconds,
                    maximumTimeoutRetries: maximumTimeoutRetries,
                    maximumRequestBytes: maximumRequestBytes,
                    filename: filename, client: client, progress: progress,
                    completedBeforePage: completedBeforePage
                )
                try Task.checkCancellation()
                return result
            } catch is CancellationError { throw RecognitionFailure.canceled }
            catch let error as SlateSyncError {
                let disposition = FailoverErrorClassifier.disposition(error)
                guard disposition != .none else { throw error }
                lastError = error
                if disposition == .provider { await state.markUnavailable(candidate.providerID) }
            }
        }
        // A failed page never makes the partial sheet look complete. The
        // caller's task group cancels peers and retains already merged pages.
        let message = candidates.count > 1
            ? "主服务与备用服务均不可用，请稍后重试或检查设置"
            : "主服务不可用，请在全局设置中配置备用服务或稍后重试"
        // Retain a safe failure category in diagnostics instead of discarding
        // the last cause. Never copy raw provider text into logs or the UI.
        let detail = lastError.map { ProductPrivacy.error($0).message }
        throw SlateSyncError(code: "PROVIDER_FAILOVER_EXHAUSTED", message: detail.map { message + "（" + $0 + "）" } ?? message,
            status: lastError?.status, providerError: true)
    }

    private func recognizePageAttempt(
        _ page: RecognitionPageInput,
        count: Int,
        provider: ProviderDescriptor,
        model: ResolvedModel,
        accuracy: ProjectSettings.AccuracyMode,
        prompts: (primary: String, audit: String, review: String),
        timeoutMilliseconds: Int,
        maximumTimeoutRetries: Int,
        maximumRequestBytes: Int,
        filename: String,
        client: ProviderRecognitionClient,
        progress: ProgressSink?,
        completedBeforePage: Int
    ) async throws -> PageOutput {
        let pageName = "\(filename) · 第 \(page.pageNumber)/\(count) 页"
        let percent = Int((35 + Double(completedBeforePage) / Double(count) * 60).rounded())
        do {
            progress?(.init(phase: "primary", completed: completedBeforePage, total: count, message: "正在主识别第 \(page.pageNumber)/\(count) 页", percent: percent, pageNumber: page.pageNumber))
            let primaryInstruction = [page.fullOCREvidence, page.layoutInstruction].filter { !$0.isEmpty }.joined(separator: "\n")
            let primaryRequest = request(page: page, stage: .primary, images: page.views.map(\.image), provider: provider, model: model, filename: pageName, prompt: prompts.primary, instruction: primaryInstruction, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries, budget: maximumRequestBytes)
            if accuracy == .standard {
                let (sheet, response) = try await Self.stage(primaryRequest, client: client, pageNumber: page.pageNumber)
                return .init(pageNumber: page.pageNumber, result: sheet, responses: [response])
            }

            progress?(.init(phase: "audit", completed: completedBeforePage, total: count, message: "正在独立查漏第 \(page.pageNumber)/\(count) 页", percent: percent, pageNumber: page.pageNumber))
            // Fixed legacy detail crops may omit right-hand camera columns.
            // Keep the full page as a reference for audit and review; filtered
            // OCR evidence alone is not proof of content outside attached crops.
            let coreImages = page.views.map(\.image)
            let referenceInstruction = "\n附有同页完整参照图，用于核对局部图未覆盖的列；请结合局部放大图复核全部摄影机区块，不要仅依据 OCR 文字作答。"
            let auditRequest = request(page: page, stage: .audit, images: coreImages, provider: provider, model: model, filename: pageName + " · 核心字段查漏", prompt: prompts.audit + referenceInstruction, instruction: page.coreOCREvidence, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries, budget: maximumRequestBytes)
            async let primaryStage = Self.stage(primaryRequest, client: client, pageNumber: page.pageNumber)
            async let auditStage = Self.stage(auditRequest, client: client, pageNumber: page.pageNumber)
            let ((primary, first), (audit, second)) = try await (primaryStage, auditStage)
            let combined = RecognitionPostprocessor.mergeHighAccuracy(primary, audit)
            guard !combined.conflicts.isEmpty || !combined.auditOnlyKeys.isEmpty else {
                return .init(pageNumber: page.pageNumber, result: combined.result, responses: [first, second])
            }

            let targets = combined.conflicts.map { conflict in
                "\(conflict.key)（两次识别冲突；冲突字段：\(conflict.fields.joined(separator: "、"))）"
            } + combined.auditOnlyKeys.map { "\($0)（仅核心查漏发现；请先确认图中确实存在此素材）" }
            progress?(.init(phase: "review", completed: completedBeforePage, total: count, message: "正在复核第 \(page.pageNumber) 页的 \(targets.count) 个冲突或查漏候选", percent: percent, pageNumber: page.pageNumber))
            let targetKeys = Set(combined.conflicts.map(\.key) + combined.auditOnlyKeys)
            let targetRecords = combined.result.records.filter { record in
                RecognitionNormalizer.materialKey(record).map(targetKeys.contains) ?? false
            }
            let reviewImages = try await page.reviewImageProvider?(targetRecords)
                ?? RecognitionReviewImages(images: coreImages, evidence: page.coreOCREvidence)
            guard !reviewImages.images.isEmpty, reviewImages.images.count <= 3,
                  reviewImages.images.first == coreImages.first else { throw RecognitionFailure.invalidInput }
            let reviewInstruction = "只复核以下 \(targets.count) 个素材键；图中找不到的键不要输出：\n" + targets.joined(separator: "\n") + evidenceSuffix(reviewImages.evidence)
            let reviewRequest = request(page: page, stage: .review, images: reviewImages.images, provider: provider, model: model, filename: pageName + " · 冲突复核", prompt: prompts.review + referenceInstruction, instruction: reviewInstruction, timeout: timeoutMilliseconds, retries: maximumTimeoutRetries, budget: maximumRequestBytes)
            let (review, third) = try await Self.stage(reviewRequest, client: client, pageNumber: page.pageNumber)
            let resolved = RecognitionPostprocessor.applyReview(combined, review: review)
            let result = RecognitionSheet(sheetTitle: resolved.sheetTitle, records: resolved.records,
                warnings: resolved.warnings + (reviewImages.warning.map { [$0] } ?? []))
            return .init(pageNumber: page.pageNumber, result: result, responses: [first, second, third])
        } catch is CancellationError { throw RecognitionFailure.canceled }
        catch let error as SlateSyncError { throw RecognitionFailure.page(error, page: page.pageNumber, count: count) }
        catch { throw RecognitionFailure.page(error, page: page.pageNumber, count: count) }
    }

    private nonisolated static func stage(
        _ request: RecognitionStageRequest,
        client: ProviderRecognitionClient,
        pageNumber: Int
    ) async throws -> (RecognitionSheet, RecognitionStageResponse) {
        let result = try await client.recognizeStructured(request) { value in
            var report = RecognitionNormalizationReport()
            return try RecognitionNormalizer.normalize(value, pageNumber: pageNumber, report: &report)
        }
        guard !result.actions.isEmpty else { return (result.value, result.response) }
        // Repairs are visible through the existing warnings channel. Their
        // audit trail remains separate from the unchanged raw response text.
        let summary = result.actions.map(\.rawValue).joined(separator: "、")
        let sheet = RecognitionSheet(
            sheetTitle: result.value.sheetTitle,
            records: result.value.records,
            warnings: result.value.warnings + ["结构化输出已进行文本修复：\(summary)；请核对该页结果。"]
        )
        return (sheet, result.response)
    }

    private func request(page: RecognitionPageInput, stage: RecognitionStage, images: [PreparedImage], provider: ProviderDescriptor, model: ResolvedModel, filename: String, prompt: String, instruction: String, timeout: Int, retries: Int, budget: Int) -> RecognitionStageRequest {
        .init(provider: provider, model: model, stage: stage, filename: filename, images: images, systemPrompt: prompt + page.scenarioInstruction, userInstruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instruction, schema: stage == .primary ? RecognitionSchemas.full : RecognitionSchemas.core, timeoutMilliseconds: timeout, maximumTimeoutRetries: retries, maximumRequestBytes: budget)
    }

    private func evidenceSuffix(_ evidence: String) -> String {
        let value = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "" : "\n\n" + value
    }
}
