import PDFKit
import Darwin
import Foundation
import SlateSyncDomain

public actor MediaPreparationService: MediaPreparing, MediaRecompressing {
    public static let maximumPages = 20
    private let clock: any OCRClock
    public init(clock: any OCRClock = SystemOCRClock()) { self.clock = clock }

    /// Opt-in strategies share the legacy reader's file and size protections.
    /// Only compressed source bytes survive between page requests.
    public func recognitionSource(_ input: MediaInput, maximumInputBytes: Int = 20 * 1024 * 1024,
                                  operation: MediaOperation) throws -> RecognitionPageSource {
        try operation.check()
        let (data, filename) = try read(input, maximum: maximumInputBytes, operation: operation)
        let source = try RecognitionPageSource(data: data, filename: filename)
        try operation.check()
        return source
    }

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
                        return try PreparedImageEncoder.views(PDFRasterizer.render(page), operation: operation, includesDetails: options.includesDetails)
                    }
                    try operation.check()
                    pages.append(.init(pageNumber: index + 1, views: views))
                    try report(index + 1, document.pageCount)
                }
            } else {
                let views = try autoreleasepool { try PreparedImageEncoder.views(ImageRasterizer.decode(data), operation: operation, includesDetails: options.includesDetails) }
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
    /// Detect split points before allocating any raster views. Each child still
    /// passes through the normal document/page/byte admission path.
    public func intakeParts(for url: URL) throws -> [MediaIntakePart] {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw MediaFailure.invalidInput }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let signature = try file.read(upToCount: 12) ?? Data()
        let size = attributes.fileSize ?? 0
        if !signature.starts(with: Data("%PDF-".utf8)) {
            let jpeg = signature.starts(with: [0xff, 0xd8, 0xff])
            let png = signature.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            let webp = signature.starts(with: Data("RIFF".utf8)) && signature.suffix(4) == Data("WEBP".utf8)
            guard jpeg || png || webp else { throw SlateSyncError(code: "MEDIA_IMAGE_DECODE", message: "请选择 PDF、JPEG、PNG 或 WebP 文件。") }
            guard size <= MediaPreparationOptions().maximumInputBytes else { throw sizeError() }
            return [.init(url: url)]
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw MediaFailure.invalidInput }
        guard !document.isLocked else { throw SlateSyncError(code: "PDF_PASSWORD", message: "PDF 已加密，请先移除密码") }
        if document.pageCount <= Self.maximumPages && size <= MediaPreparationOptions().maximumInputBytes { return [.init(url: url)] }
        var parts: [MediaIntakePart] = []
        func append(_ range: ClosedRange<Int>) throws {
            try Task.checkCancellation()
            let bytes = try pdfPart(document, range)
            if bytes.count <= MediaPreparationOptions().maximumInputBytes {
                parts.append(.init(url: url, pages: range))
            } else {
                guard range.count > 1 else { throw sizeError() }
                let middle = range.lowerBound + range.count / 2 - 1
                try append(range.lowerBound...middle)
                try append((middle + 1)...range.upperBound)
            }
        }
        for start in stride(from: 1, through: document.pageCount, by: Self.maximumPages) {
            try append(start...min(document.pageCount, start + Self.maximumPages - 1))
        }
        return parts
    }

    private func pdfPart(_ document: PDFDocument, _ range: ClosedRange<Int>) throws -> Data {
        let part = PDFDocument()
        for page in range {
            guard let item = document.page(at: page - 1)?.copy() as? PDFPage else { throw MediaFailure.invalidInput }
            part.insert(item, at: part.pageCount)
        }
        guard let bytes = part.dataRepresentation() else { throw MediaFailure.invalidInput }
        return bytes
    }

    public func previewPart(_ part: MediaIntakePart) async throws -> MediaIntakePreview {
        let options = MediaPreparationOptions(includesDetails: false)
        let bytes: Data
        if let pages = part.pages {
            guard let pdf = PDFDocument(url: part.url), !pdf.isLocked else { throw MediaFailure.invalidInput }
            bytes = try pdfPart(pdf, pages)
        } else {
            bytes = try read(.file(part.url), maximum: options.maximumInputBytes, operation: .init()).0
        }
        let document = try await prepare(.bytes(bytes, filename: part.filename), options: options)
        return .init(document: document, original: bytes)
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
