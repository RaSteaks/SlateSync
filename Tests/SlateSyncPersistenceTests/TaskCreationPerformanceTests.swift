import Foundation
import SlateSyncDomain
import XCTest

@testable import SlateSyncPersistence

/// Opt-in, headless measurements use synthetic encrypted projects only. Keep
/// wall-clock budgets out of functional CI; retain raw samples for comparison.
@MainActor
final class TaskCreationPerformanceTests: XCTestCase {
    func testEncryptedCreationStages() async throws {
        guard let output = ProcessInfo.processInfo.environment["SLATESYNC_TASK_CREATION_BENCHMARK_DIR"] else {
            throw XCTSkip("Set SLATESYNC_TASK_CREATION_BENCHMARK_DIR for offline timing samples")
        }
        var reports: [[String: Any]] = []
        for (count, imageBytes) in [(0, 0), (16, 64 * 1024), (64, 256 * 1024), (128, 512 * 1024)] {
            let root = try PersistenceTestSupport.temporaryRoot("task-creation-timing")
            defer { try? FileManager.default.removeItem(at: root) }
            try await LocalProjectEncryption.prepare(at: root, backend: InMemoryKeychainBackend())
            let database = try SQLiteDatabase(url: root.appending(path: SQLiteV1.projectDatabaseFilename))
            try await SQLiteV1.bootstrapProject(database)
            // Seed in one transaction so fixture construction is not measured.
            let image = String(repeating: "A", count: imageBytes)
            try await database.transaction((0..<count).map { index in
                let seed = try JSONEncoder().encode(TaskData(id: "seed-\(index)",
                    filename: "Synthetic", imageDataGroups: [[image]]))
                return SQLiteCommand("INSERT INTO tasks VALUES (?, ?, ?, ?);", bindings: [
                    "seed-\(index)", String(decoding: seed, as: UTF8.self),
                    "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z",
                ])
            })
            try await database.close()
            let store = try ProjectTaskStore(projectDirectory: root)
            _ = try await store.listTasks()
            let payload = try JSONEncoder().encode(TaskData(status: "draft", filename: "New task", customPrompt: ""))
            let clock = ContinuousClock()
            var samples: [[String: Double]] = []
            var combinedSamples: [[String: Double]] = []
            for _ in 0..<5 {
                let start = clock.now
                let id = try await store.saveTask(payload)
                let saved = clock.now
                let items = try await store.listTasks()
                let listed = clock.now
                let task = try JSONDecoder().decode(TaskData.self, from: await store.loadTask(id))
                let loaded = clock.now
                XCTAssertEqual(items.count, count + 1)
                XCTAssertEqual(task.id, id)
                samples.append([
                    "saveMs": milliseconds(start.duration(to: saved)),
                    "listMs": milliseconds(saved.duration(to: listed)),
                    "loadMs": milliseconds(listed.duration(to: loaded)),
                    "totalMs": milliseconds(start.duration(to: loaded)),
                ])
                // Restore the same task count between paths; cleanup and
                // assertions are outside both measured creation intervals.
                try await store.deleteTask(id)
                let combinedStart = clock.now
                let result = try await store.createTask(payload)
                let combinedEnd = clock.now
                XCTAssertEqual(result.tasks.count, count + 1)
                XCTAssertNotNil(result.task.createdAt)
                combinedSamples.append(["totalMs": milliseconds(combinedStart.duration(to: combinedEnd))])
                try await store.deleteTask(try XCTUnwrap(result.task.id))
            }
            let size = try Data(contentsOf: store.databaseURL).count
            try await store.close()
            reports.append(["existingTasks": count, "imageBytesPerTask": imageBytes,
                "databaseBytes": size, "legacy": samples, "combined": combinedSamples])
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "task-creation-timing.json"), options: .atomic)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
