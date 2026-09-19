import Foundation

/// Environment checks are independent of engine enablement and never imply
/// that recognition models have been downloaded or inference has succeeded.
public struct OCREnvironmentCheck: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable { case passed, failed, warning }
    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    public init(id: String, title: String, status: Status, detail: String) {
        self.id = id; self.title = title; self.status = status; self.detail = detail
    }
}

public extension GlobalSettingsWorkflowServing {
    // Non-platform service doubles explicitly report unsupported diagnostics.
    func checkOCREnvironment(values: GlobalSettingValues) async throws -> [OCREnvironmentCheck] {
        throw SlateSyncError(code: "OCR_CHECK_UNAVAILABLE", message: "当前服务不支持 OCR 环境检测")
    }
}
