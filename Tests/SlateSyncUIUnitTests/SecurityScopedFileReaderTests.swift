import XCTest
@testable import SlateSyncUI

/// Contract for the shared fileImporter read path: bytes survive the
/// background hop, and every failure (missing file, denied permissions)
/// throws instead of silently returning empty data — the views funnel the
/// thrown error into model.report, so swallowing here would hide breakage.
@MainActor
final class SecurityScopedFileReaderTests: XCTestCase {
    func testReadReturnsExactFileBytes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("回填-\(UUID().uuidString).csv")
        let expected = Data("\u{FEFF}Scene,Shot,Take\r\n001,02,03\r\n".utf8)
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try await SecurityScopedFileReader.read(url)
        XCTAssertEqual(data, expected)
    }

    func testReadThrowsForMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("缺失-\(UUID().uuidString).csv")
        do {
            _ = try await SecurityScopedFileReader.read(url)
            XCTFail("缺失文件必须抛错")
        } catch { }
    }

    func testReadThrowsForPermissionDeniedFile() async throws {
        guard geteuid() != 0 else { throw XCTSkip("权限拒绝用例要求非 root 运行") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("拒绝-\(UUID().uuidString).csv")
        try Data("sealed".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }

        do {
            _ = try await SecurityScopedFileReader.read(url)
            XCTFail("无权限读取必须抛错")
        } catch { }
    }

    func testParallelReadsAllComplete() async throws {
        // Concurrent picks (drag-restore, quick re-import) must not serialize
        // on or deadlock against the main actor.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("并发-\(UUID().uuidString).csv")
        let expected = Data("Scene,Shot,Take\r\n001,02,03\r\n".utf8)
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await SecurityScopedFileReader.read(url) } }
            var results: [Data] = []
            for try await data in group { results.append(data) }
            XCTAssertEqual(results.count, 8)
            XCTAssertEqual(Set(results), [expected])
        }
    }
}
