import Foundation
import XCTest
@testable import SlateSyncPersistence

final class ProjectLibraryStoreTests: XCTestCase {
    func testCreatesAndListsProjectInIsolatedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SlateSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try ProjectLibraryStore(applicationSupportRoot: root)
        _ = try await store.createProject(name: "测试项目", description: "隔离数据")
        let projects = try await store.listProjects()
        XCTAssertEqual(projects.map(\.name), ["测试项目"])
    }
