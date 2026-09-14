import Foundation
import Observation

/// The stable categories shared by Help and the native Settings scene. The
/// raw values are internal route identifiers, not localized view titles.
public enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case providers
    case recognition
    case ocr
    case advanced

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "通用"
        case .providers: "Provider"
        case .recognition: "识别"
        case .ocr: "OCR"
        case .advanced: "高级"
        }
    }
}

/// Optional subregions let a help action land on a meaningful section inside
/// the OCR form without coupling the help resource to SwiftUI labels.
public enum SettingsSubregion: String, Hashable, Sendable {
    case vision
    case paddleOCR
}

public struct SettingsNavigationRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let category: SettingsCategory
    public let subregion: SettingsSubregion?
    public let providerID: String?

    public init(
        id: UUID = UUID(),
        category: SettingsCategory,
        subregion: SettingsSubregion? = nil,
        providerID: String? = nil
    ) {
        self.id = id
        self.category = category
        self.subregion = subregion
        self.providerID = providerID
    }
}

/// App-level navigation state is deliberately tiny. A fresh UUID on every
/// request means repeated clicks are observable even when the destination is
/// already selected or the same Provider sheet is currently visible.
@MainActor @Observable
public final class SettingsNavigationModel {
    public private(set) var pendingRequest: SettingsNavigationRequest?

    public init() {}

    public func navigate(
        to category: SettingsCategory,
        subregion: SettingsSubregion? = nil,
        providerID: String? = nil
    ) {
        pendingRequest = SettingsNavigationRequest(
            category: category,
            subregion: subregion,
            providerID: providerID
        )
    }

    public func consume(_ request: SettingsNavigationRequest) {
        guard pendingRequest?.id == request.id else { return }
        pendingRequest = nil
    }
}
