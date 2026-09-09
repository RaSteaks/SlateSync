import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SlateSyncDomain
import SlateSyncPersistence
import SlateSyncWorkflow
import UniformTypeIdentifiers
import XCTest

/// SM-09 #12: reopening a persisted task must restore every saved view
/// exactly — count, order, type and JPEG bytes — instead of re-preparing only
/// the first image. Legacy tasks that saved one full image per page keep the
/// bounded re-preparation fallback.
@MainActor
final class PreparedMediaRestoreTests: XCTestCase {
    /// Deterministic slate-like JPEG: white ground with seeded black bands so
    /// the bytes are non-trivial and any re-encode changes the hash.
    private func jpeg(width: Int, height: Int, seed: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for band in 0..<8 {
            context.fill(CGRect(
                x: 20 + seed * 7, y: 30 + band * (height / 10),
                width: width - 60, height: max(2, height / 60)
            ))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func view(_ index: Int, _ type: PreparedViewType, _ jpeg: Data, width: Int, height: Int) throws -> PreparedMediaView {
        .init(viewIndex: index, viewType: type, image: try PreparedImage(jpeg: jpeg, width: width, height: height))
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "slatesync-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFacade(root: URL) throws -> SlateSyncWorkflowFacade {
        let locator = ApplicationSupportLocator(root: root.appending(path: "AppSupport", directoryHint: .isDirectory))
        let runtime = SlateSyncRuntime(locator: locator, environment: [:], keychainBackend: nil)
        let library = ProjectLibraryStartupService(
            locator: locator,
            machineSettings: runtime.machineSettingsStore,
            forceIsolatedRoot: true
        )
        return SlateSyncWorkflowFacade(
            library: library,
            runtime: runtime,
            logs: LocalLogStore(directory: root.appending(path: "logs", directoryHint: .isDirectory)),
            paddleInstaller: PaddleOCRInstallerService(
                userDataRoot: locator.url,
                requirementsURL: root.appending(path: "requirements-ocr.txt")
            ),
            allowsExternalOperations: false
        )
    }

    private func expectFailure(_ message: String, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail(message) } catch {}
    }

    func testRestoreRebuildsEveryViewWithOriginalBytesOrderAndType() async throws {
        let root = try temporaryRoot("media-restore-exact")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = try makeFacade(root: root)
        let saved = PreparedDocument(filename: "场记单.jpg", pages: [
            .init(pageNumber: 1, views: [
                try view(0, .full, try jpeg(width: 1600, height: 2000, seed: 1), width: 1600, height: 2000),
                try view(1, .coreDetail, try jpeg(width: 1000, height: 1400, seed: 2), width: 1000, height: 1400),
            ]),
            .init(pageNumber: 2, views: [
                try view(0, .full, try jpeg(width: 1200, height: 1500, seed: 3), width: 1200, height: 1500),
                try view(1, .coreDetail, try jpeg(width: 800, height: 1100, seed: 4), width: 800, height: 1100),
                try view(2, .coreDetail, try jpeg(width: 600, height: 900, seed: 5), width: 600, height: 900),
            ]),
        ])
        let groups = saved.pages.map { $0.views.map { $0.image.dataURL } }

        let restored = try await facade.restoreInput(groups: groups, filename: saved.filename)

        XCTAssertEqual(restored.filename, saved.filename)
        XCTAssertEqual(restored.pages.map(\.pageNumber), saved.pages.map(\.pageNumber))
        for (savedPage, restoredPage) in zip(saved.pages, restored.pages) {
            XCTAssertEqual(restoredPage.views.count, savedPage.views.count)
            for (savedView, restoredView) in zip(savedPage.views, restoredPage.views) {
                XCTAssertEqual(restoredView.viewIndex, savedView.viewIndex)
                XCTAssertEqual(restoredView.viewType, savedView.viewType)
                XCTAssertEqual(restoredView.image.width, savedView.image.width)
                XCTAssertEqual(restoredView.image.height, savedView.image.height)
                XCTAssertEqual(hash(restoredView.image.jpeg), hash(savedView.image.jpeg))
            }
        }
    }

    func testRestoreLegacySingleFullImageStillRepreparesThroughPreparation() async throws {
        let root = try temporaryRoot("media-restore-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = try makeFacade(root: root)
        let filename = "legacy.jpg"
        let page = try jpeg(width: 1600, height: 2000, seed: 6)
        let groups = [["data:image/jpeg;base64," + page.base64EncodedString()]]

        let restored = try await facade.restoreInput(groups: groups, filename: filename)
        let prepared = try await facade.prepareInput(.bytes(page, filename: filename))

        XCTAssertEqual(restored.filename, filename)
        XCTAssertEqual(restored.pages.map(\.pageNumber), [1])
        XCTAssertEqual(restored.pages.count, prepared.pages.count)
        for (preparedPage, restoredPage) in zip(prepared.pages, restored.pages) {
            XCTAssertEqual(restoredPage.views.count, preparedPage.views.count)
            for (preparedView, restoredView) in zip(preparedPage.views, restoredPage.views) {
                XCTAssertEqual(restoredView.viewIndex, preparedView.viewIndex)
                XCTAssertEqual(restoredView.viewType, preparedView.viewType)
                XCTAssertEqual(hash(restoredView.image.jpeg), hash(preparedView.image.jpeg))
            }
        }
    }

    func testRestoreMixedTaskKeepsSingleViewPageBytesExact() async throws {
        let root = try temporaryRoot("media-restore-mixed")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = try makeFacade(root: root)
        let fullOnly = try jpeg(width: 1400, height: 1800, seed: 7)
        let saved = PreparedDocument(filename: "mixed.jpg", pages: [
            .init(pageNumber: 1, views: [
                try view(0, .full, fullOnly, width: 1400, height: 1800),
            ]),
            .init(pageNumber: 2, views: [
                try view(0, .full, try jpeg(width: 1200, height: 1500, seed: 8), width: 1200, height: 1500),
                try view(1, .coreDetail, try jpeg(width: 900, height: 1200, seed: 9), width: 900, height: 1200),
            ]),
        ])
        let groups = saved.pages.map { $0.views.map { $0.image.dataURL } }

        let restored = try await facade.restoreInput(groups: groups, filename: saved.filename)

        // A single-view page inside a multi-view task is already prepared by
        // the current save path; restoring it must not re-crop or re-encode.
        XCTAssertEqual(restored.pages[0].views.count, 1)
        XCTAssertEqual(hash(restored.pages[0].views[0].image.jpeg), hash(fullOnly))
    }

    func testRestoreFailsClosedOnCorruptOrMalformedDataURLs() async throws {
        let root = try temporaryRoot("media-restore-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let facade = try makeFacade(root: root)
        let valid = try jpeg(width: 800, height: 1000, seed: 10)
        let dataURL = "data:image/jpeg;base64," + valid.base64EncodedString()

        await expectFailure("非图像负载必须失败") {
            _ = try await facade.restoreInput(
                groups: [[dataURL, "data:image/jpeg;base64," + Data("not an image".utf8).base64EncodedString()]],
                filename: "corrupt.jpg"
            )
        }
        await expectFailure("缺少 data URL 前缀必须失败") {
            _ = try await facade.restoreInput(groups: [[valid.base64EncodedString()]], filename: "prefix.jpg")
        }
        await expectFailure("空页分组必须失败") {
            _ = try await facade.restoreInput(groups: [[dataURL], []], filename: "empty.jpg")
        }
        await expectFailure("超出视图上限的分组必须失败") {
            _ = try await facade.restoreInput(
                groups: [[dataURL, dataURL, dataURL, dataURL]],
                filename: "overflow.jpg"
            )
        }
    }
}
