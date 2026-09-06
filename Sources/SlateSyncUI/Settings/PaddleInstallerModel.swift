import Observation
import SlateSyncDomain

/// Settings-scoped projection for the application-owned installer. Raw child
/// output and environment never enter observable state; only frozen progress
/// stages and verified public versions are published.
@MainActor @Observable
public final class PaddleInstallerModel {
    public private(set) var operation: OperationState = .idle
    public private(set) var progress: PaddleOcrInstallProgress?
    public private(set) var result: PaddleOcrInstallResult?
    private let service: any GlobalSettingsWorkflowServing
    private var task: Task<Void, Never>?
    private var cancelTask: Task<Void, Never>?
    private var acceptsOperations = true

    public init(service: any GlobalSettingsWorkflowServing) { self.service = service }

    public func install() {
        guard task == nil, acceptsOperations else { return }
        operation = .running(label: "正在准备 PaddleOCR 安装…")
        progress = nil
        result = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let installed = try await service.installPaddleOCR { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.task != nil else { return }
                        // The service callback is synchronous, but each
                        // MainActor hop is independently scheduled. Reject a
                        // late stage instead of letting visible progress move
                        // backward while installation is still active.
                        guard value.percent >= (self.progress?.percent ?? -.infinity) else { return }
                        self.progress = value
                        self.operation = .running(label: value.message)
                    }
                }
                result = installed
                operation = .succeeded(message: "PaddleOCR 已安装")
            } catch {
                let wrapped = ProductPrivacy.error(error)
                operation = wrapped.code == "PADDLEOCR_INSTALL_CANCELED" ? .canceled : .failed(wrapped)
            }
            task = nil
        }
    }

    public func cancel() {
        guard task != nil, cancelTask == nil, acceptsOperations else { return }
        operation = .running(label: "正在取消 PaddleOCR 安装…")
        let service = self.service
        // Retain the service hop so application drain can join exactly the
        // cancellation requested by the user instead of racing a duplicate.
        cancelTask = Task { [weak self] in
            await service.cancelPaddleOCRInstallation()
            self?.cancelTask = nil
        }
    }

    public func drain() async {
        // Installation includes its final persisted Python path; join the
        // entire model task rather than only the installer child process.
        acceptsOperations = false
        if let cancelTask { await cancelTask.value }
        else { await service.cancelPaddleOCRInstallation() }
        await task?.value
        // Re-read the retained task after installation resumes so a cancel
        // admitted immediately before drain closed admission is also joined.
        await cancelTask?.value
    }
}
