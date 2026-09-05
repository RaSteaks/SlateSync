import Foundation
import Synchronization

/// Source bytes are confined to preparation. Downstream values have no PDF slot.
public enum MediaInput: Sendable {
    case file(URL)
    case bytes(Data, filename: String)
}

public struct MediaPreparationOptions: Sendable {
    public let maximumInputBytes: Int
    public init(maximumInputBytes: Int = 20 * 1024 * 1024) {
        self.maximumInputBytes = maximumInputBytes
    }
}

public enum PreparedViewType: String, Codable, Sendable { case full, coreDetail = "core-detail" }
public enum MediaAccuracy: String, Codable, Sendable { case standard, high }

/// A validated JPEG container; decoding also goes through this initializer so
/// a historical direct-PDF body cannot masquerade as a prepared image value.
public struct PreparedImage: Codable, Hashable, Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public init(jpeg: Data, width: Int, height: Int) throws {
        guard width > 0, height > 0, jpeg.starts(with: [0xff, 0xd8, 0xff]),
              jpeg.count >= 4, jpeg.suffix(2) == Data([0xff, 0xd9]) else {
            throw SlateSyncError(code: "OCR_IMAGE", message: "页面必须是有效的 JPEG 图像")
        }
        self.jpeg = jpeg; self.width = width; self.height = height
    }
    public var dataURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
    private enum CodingKeys: String, CodingKey { case jpeg, width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(jpeg: c.decode(Data.self, forKey: .jpeg), width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height))
    }
}

public struct PreparedMediaView: Codable, Hashable, Sendable {
    public let viewIndex: Int
    public let viewType: PreparedViewType
    public let image: PreparedImage
    public init(viewIndex: Int, viewType: PreparedViewType, image: PreparedImage) {
        self.viewIndex = viewIndex; self.viewType = viewType; self.image = image
    }
}

public struct PreparedMediaPage: Codable, Hashable, Sendable {
    public let pageNumber: Int
    public let views: [PreparedMediaView]
    public init(pageNumber: Int, views: [PreparedMediaView]) {
        self.pageNumber = pageNumber; self.views = views
    }
}

public struct PreparedDocument: Codable, Hashable, Sendable {
    public let filename: String
    public let pages: [PreparedMediaPage]
    public init(filename: String, pages: [PreparedMediaPage]) {
        self.filename = filename; self.pages = pages
    }
    public var viewCount: Int { pages.reduce(0) { $0 + $1.views.count } }
    public func selected(_ accuracy: MediaAccuracy) -> Self {
        .init(filename: filename, pages: pages.map { .init(pageNumber: $0.pageNumber, views: accuracy == .standard ? Array($0.views.prefix(1)) : $0.views) })
    }
    public func validate() throws {
        guard !pages.isEmpty, pages.count <= 20 else { throw MediaFailure.invalidInput }
        for (index, page) in pages.enumerated() {
            guard page.pageNumber == index + 1, !page.views.isEmpty, page.views.count <= 3 else { throw MediaFailure.invalidInput }
            for (index, view) in page.views.enumerated() {
                guard view.viewIndex == index, view.viewType == (index == 0 ? .full : .coreDetail) else { throw MediaFailure.invalidInput }
            }
        }
    }
    /// Only this compatibility entrance reads the old field, and it fails
    /// before any preparation, OCR or downstream side effect.
    public static func rejectLegacyPDF(in payload: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: payload)
        if case .object(let fields) = value, fields["pdfDataUrl"] != nil {
            throw SlateSyncError(code: "DIRECT_PDF_UNSUPPORTED", message: "请先将 PDF 转为页面图片")
        }
    }
}

public struct ImageCompressionProfile: Codable, Hashable, Sendable {
    public let maxDimension: Int
    public let quality: Double
    public init(maxDimension: Int, quality: Double) { self.maxDimension = maxDimension; self.quality = quality }
    public static let requestProfiles: [Self] = [.init(maxDimension: 2200, quality: 0.82), .init(maxDimension: 1800, quality: 0.74), .init(maxDimension: 1500, quality: 0.68)]
}

public struct MediaProgress: Codable, Hashable, Sendable {
    public let stage: String
    public let completed: Int
    public let total: Int
    public init(stage: String, completed: Int, total: Int) { self.stage = stage; self.completed = completed; self.total = total }
}
public typealias MediaProgressSink = @Sendable (MediaProgress) -> Void

/// Cancellation is a value-only latch shared with synchronous framework work.
/// No PDF/Vision/Process object crosses its owning execution domain.
public final class MediaOperation: Sendable {
    private let canceled = Mutex(false)
    public init() {}
    public func cancel() { canceled.withLock { $0 = true } }
    public var isCanceled: Bool { canceled.withLock { $0 } }
    public func check() throws {
        if isCanceled || Task.isCancelled { throw MediaFailure.canceled }
    }
}

public enum MediaFailure {
    public static let canceled = SlateSyncError(code: "RECOGNITION_CANCELED", message: "识别已取消")
    public static let invalidInput = SlateSyncError(code: "MEDIA_INPUT", message: "页面输入无效")
    public static let timeout = SlateSyncError(code: "OCR_TIMEOUT", message: "本地 OCR 超时", retryable: true)
    public static let protocolError = SlateSyncError(code: "OCR_PROTOCOL", message: "本地 OCR 返回无效协议数据", retryable: true)
    public static let closed = SlateSyncError(code: "OCR_CLOSED", message: "本地 OCR 服务已关闭")
    public static let unavailable = SlateSyncError(code: "OCR_UNAVAILABLE", message: "本地 OCR 运行环境不可用")
    public static func isTerminal(_ error: any Error) -> Bool {
        error is CancellationError || ["RECOGNITION_CANCELED", "OCR_CLOSED"].contains((error as? SlateSyncError)?.code ?? "")
    }
}
