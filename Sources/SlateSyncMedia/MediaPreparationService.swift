import Darwin
import Foundation
import SlateSyncDomain

public actor MediaPreparationService: MediaPreparing, MediaRecompressing {
    public static let maximumPages = 20
    private let clock: any OCRClock
    public init(clock: any OCRClock = SystemOCRClock()) { self.clock = clock }

    public func prepare(_ input: MediaInput, options: MediaPreparationOptions = .init(), operation: MediaOperation = .init(), progress: MediaProgressSink? = nil) async throws -> PreparedDocument {
        try await withTaskCancellationHandler {
            try operation.check()
            let (data, filename) = try read(input, maximum: options.maximumInputBytes, operation: operation)
            var pages: [PreparedMediaPage] = []
            var lastProgress = -Double.infinity
            func report(_ completed: Int, _ total: Int) throws {
                try operation.check()
                let now = clock.nowMilliseconds()
                if completed == total || now - lastProgress >= 100 {
                    lastProgress = now; progress?(.init(stage: "prepare", completed: completed, total: total))
                }
            }
            if data.starts(with: Array("%PDF-".utf8)) {
                let document = try PDFRasterizer.document(data)
                for index in 0..<document.pageCount {
                    try operation.check()
                    let views = try autoreleasepool {
                        guard let page = document.page(at: index) else { throw SlateSyncError(code: "PDF_PAGE", message: "无法读取 PDF 页面") }
                        return try PreparedImageEncoder.views(PDFRasterizer.render(page), operation: operation)
                    }
                    try operation.check()
                    pages.append(.init(pageNumber: index + 1, views: views))
                    try report(index + 1, document.pageCount)
                }
            } else {
                let views = try autoreleasepool { try PreparedImageEncoder.views(ImageRasterizer.decode(data), operation: operation) }
                pages = [.init(pageNumber: 1, views: views)]
                try report(1, 1)
            }
            // Publish atomically only after every page and cancellation check.
            try operation.check()
            return .init(filename: filename, pages: pages)
        } onCancel: { operation.cancel() }
    }

    public func recompress(_ document: PreparedDocument, profile: ImageCompressionProfile, operation: MediaOperation = .init()) async throws -> PreparedDocument {
        try await withTaskCancellationHandler {
            try document.validate()
            var pages: [PreparedMediaPage] = []
            for page in document.pages {
                var views: [PreparedMediaView] = []
                for view in page.views {
                    try operation.check()
                    let image = try autoreleasepool { try PreparedImageEncoder.encode(ImageRasterizer.decode(view.image.jpeg, maximum: 3000), maximum: profile.maxDimension, quality: profile.quality) }
                    try operation.check()
                    views.append(.init(viewIndex: view.viewIndex, viewType: view.viewType, image: image))
                }
                pages.append(.init(pageNumber: page.pageNumber, views: views))
            }
            try operation.check()
            return .init(filename: document.filename, pages: pages)
        } onCancel: { operation.cancel() }
    }

    private func read(_ input: MediaInput, maximum: Int, operation: MediaOperation) throws -> (Data, String) {
        guard maximum > 0, maximum < Int.max else { throw MediaFailure.invalidInput }
        let data: Data, filename: String
        switch input {
        case .bytes(let bytes, let name): data = bytes; filename = name
        case .file(let url):
            guard url.isFileURL else { throw MediaFailure.invalidInput }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw SlateSyncError(code: "MEDIA_FILE", message: "无法读取普通文件") }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw MediaFailure.invalidInput }
            guard before.st_size <= maximum else { throw sizeError() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try operation.check()
                let amount = Darwin.read(fd, &buffer, min(buffer.count, maximum + 1 - bytes.count))
                if amount < 0 { if errno == EINTR { continue }; throw MediaFailure.invalidInput }
                if amount == 0 { break }
                bytes.append(contentsOf: buffer.prefix(amount))
                if bytes.count > maximum { throw sizeError() }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size, bytes.count == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SlateSyncError(code: "MEDIA_FILE_CHANGED", message: "读取期间文件发生变化") }
            data = bytes; filename = url.lastPathComponent
        }
        guard data.count <= maximum else { throw sizeError() }
        guard !data.isEmpty else { throw MediaFailure.invalidInput }
        try operation.check()
        return (data, filename)
    }
    private func sizeError() -> SlateSyncError { .init(code: "MEDIA_SIZE", message: "文件超出输入大小上限") }
}

public enum MediaRequestBudget {
    /// Measure the complete UTF-8 request including Base64/scenario/prompt/rows.
    /// Compression consumes the previous round and never mutates retained pages.
    public static func fit(_ document: PreparedDocument, maxRequestBytes: Int = 80 * 1024 * 1024, compressor: any MediaRecompressing, operation: MediaOperation = .init(), measure: @Sendable (PreparedDocument) throws -> Int) async throws -> PreparedDocument {
        guard maxRequestBytes > 0 else { throw MediaFailure.invalidInput }
        let target = floor(Double(maxRequestBytes) * 0.94)
        var candidate = document
        for profile in [ImageCompressionProfile?.none] + ImageCompressionProfile.requestProfiles.map(Optional.some) {
            try operation.check()
            if let profile { candidate = try await compressor.recompress(candidate, profile: profile, operation: operation) }
            let size = try measure(candidate)
            guard size >= 0 else { throw MediaFailure.invalidInput }
            try operation.check()
            if Double(size) <= target { return candidate }
        }
        throw SlateSyncError(code: "MEDIA_REQUEST_SIZE", message: "压缩后的请求仍超出大小上限")
    }
}
