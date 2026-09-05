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
        guard task != nil else { return }
        operation = .running(label: "正在取消 PaddleOCR 安装…")
        Task { await service.cancelPaddleOCRInstallation() }
    }

    public func drain() async {
        // Installation includes its final persisted Python path; join the
        // entire model task rather than only the installer child process.
        acceptsOperations = false
        await service.cancelPaddleOCRInstallation()
        await task?.value
    }
}
