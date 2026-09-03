import Foundation
import SlateSyncPersistence
import XCTest

final class SlateSyncTests: XCTestCase {
    func testAppCompositionCanOpenAnIsolatedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ProjectLibraryStore(applicationSupportRoot: root)
        let info = try await store.libraryInfo()

        XCTAssertEqual(info.formatVersion, 1)
        XCTAssertEqual(info.name, ProjectLibraryStore.defaultLibraryName)
    }
}
