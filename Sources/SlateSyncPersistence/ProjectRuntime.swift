import Foundation
import SlateSyncDomain

private struct ProjectPersistenceContext: Sendable {
    var project: ProjectData
    let tasks: ProjectTaskStore
    let scenarios: ScenarioStore
    let diagnostics: DiagnosticsStore
}

/// Lazily owns every SQLite connection for an addressable project.
///
/// The lease counter closes the actor-reentrancy gap: deletion marks a project
/// unavailable before waiting for in-flight store calls, then closes all three
/// SQLite owners before the Library starts its tombstone transaction.
public actor ProjectRuntime: TaskRepository {
    private let library: ProjectLibraryStore
    private let writer: any AtomicFileWriting
    private var contexts: [String: ProjectPersistenceContext] = [:]
    private var deletingProjects: Set<String> = []
    private var activeLeases: [String: Int] = [:]
    private var leaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var refusesNewOperations = false
    private var closeTask: Task<Void, any Error>?

    public init(
        library: ProjectLibraryStore,
        writer: any AtomicFileWriting = FileManagerAtomicFileWriter()
    ) {
        self.library = library
        self.writer = writer
    }

    public func listTaskItems(projectID: String) async throws -> [TaskListItem] {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.tasks.listTasks()
    }

    public func listTasks(projectID: String) async throws -> [String] {
        try await listTaskItems(projectID: projectID).compactMap(\.id)
    }

    public func loadTask(projectID: String, taskID: String) async throws -> Data {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.tasks.loadTask(taskID)
    }

    public func saveTask(projectID: String, taskID: String?, payload: Data) async throws -> String {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        var object = try PersistenceJSON.object(from: payload, errorCode: "TASK_INVALID")
        // The runtime, not UI state, stamps project ownership into both SQLite
        // and the compatibility snapshot at the final persistence boundary.
        object["projectId"] = projectID
        return try await context.tasks.saveTask(
            PersistenceJSON.data(from: object, errorCode: "TASK_INVALID"),
            taskID: taskID
        )
    }

    public func updateTask(projectID: String, taskID: String, patch: Data) async throws -> String {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        var object = try PersistenceJSON.object(from: patch, errorCode: "TASK_INVALID")
        // Ownership is runtime-controlled even when a caller patches a task
        // restored from an Electron-era snapshot.
        object["projectId"] = projectID
        return try await context.tasks.updateTask(
            taskID,
            patch: PersistenceJSON.data(from: object, errorCode: "TASK_INVALID")
        )
    }

    public func deleteTask(projectID: String, taskID: String) async throws {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        try await context.tasks.deleteTask(taskID)
    }

    public func listScenarios(projectID: String) async throws -> [ScenarioSummary] {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.scenarios.listProfiles()
    }

    public func loadScenario(projectID: String, scenarioID: String) async throws -> ScenarioData {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.scenarios.getProfile(scenarioID)
    }

    public func importScenario(projectID: String, profile: ScenarioProfile) async throws -> ScenarioData {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.scenarios.importProfile(profile)
    }

    @discardableResult
    public func recordScenarioObservation(
        projectID: String,
        profileID: String,
        fingerprintVersion: Int,
        fingerprint: String,
        payload: Data,
        incrementSampleCount: Bool = true
    ) async throws -> String {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.scenarios.recordObservation(
            profileID: profileID,
            fingerprintVersion: fingerprintVersion,
            fingerprint: fingerprint,
            payload: payload,
            incrementSampleCount: incrementSampleCount
        )
    }

    public func saveDiagnostic(
        projectID: String,
        sessionID: String? = nil,
        payload: Data
    ) async throws -> String {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        var object = try PersistenceJSON.object(from: payload, errorCode: "DIAGNOSTIC_INVALID")
        object["projectId"] = projectID
        return try await context.diagnostics.saveSession(
            PersistenceJSON.data(from: object, errorCode: "DIAGNOSTIC_INVALID"),
            sessionID: sessionID
        )
    }

    public func loadDiagnostic(projectID: String, sessionID: String) async throws -> Data {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.diagnostics.loadSession(sessionID)
    }

    public func listDiagnostics(projectID: String) async throws -> [DiagnosticSessionSummary] {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        return try await context.diagnostics.listSessions()
    }

    public func deleteDiagnostic(projectID: String, sessionID: String) async throws {
        let context = try await acquire(projectID)
        defer { release(projectID) }
        try await context.diagnostics.deleteSession(sessionID)
    }

    public func closeProject(_ projectID: String) async throws {
        guard !refusesNewOperations, closeTask == nil else { return }
        let id = try PersistenceIdentifiers.project(projectID)
        try beginProjectTransition(id)
        defer { endProjectTransition(id) }
        await waitForLeases(of: id)
        if let context = contexts.removeValue(forKey: id) {
            do {
                try await close(context)
            } catch {
                // A partially closed context cannot be safely reopened. Make
                // the whole runtime reject new work; close() can still drain
                // and explicitly close every other retained context.
                refusesNewOperations = true
                throw error
            }
        }
    }

    public func deleteProject(_ projectID: String) async throws -> String {
        guard !refusesNewOperations, closeTask == nil else {
            throw SlateSyncError(code: "PROJECT_RUNTIME_CLOSED", message: "项目运行时已关闭")
        }
        let id = try PersistenceIdentifiers.project(projectID)
        guard id != ProjectLibraryStore.defaultProjectID else {
            throw SlateSyncError(code: "PROJECT_DEFAULT_PROTECTED", message: "默认项目不能删除")
        }
        try beginProjectTransition(id)
        defer { endProjectTransition(id) }
        await waitForLeases(of: id)
        if let context = contexts.removeValue(forKey: id) {
            do {
                try await close(context)
            } catch {
                refusesNewOperations = true
                throw error
            }
        }
        return try await library.deleteProject(id)
    }

    public func close() async throws {
        if let closeTask {
            try await closeTask.value
            return
        }
        // Publish the terminal state before the first await so a reentrant
        // caller cannot open a fresh context while shutdown drains leases.
        refusesNewOperations = true
        let task = Task<Void, any Error> { try await self.performClose() }
        closeTask = task
        try await task.value
    }

    private func performClose() async throws {
        // A delete/closeProject that began before shutdown owns its marker
        // until its Library mutation finishes. Waiting prevents close() from
        // returning while that terminal operation is still reentrant.
        await waitForProjectTransitions()
        let ids = Set(contexts.keys)
        deletingProjects.formUnion(ids)
        for id in ids { await waitForLeases(of: id) }
        let values = Array(contexts.values)
        contexts.removeAll()
        // Attempt every owner even when an earlier project reports a close
        // error. This leaves no later project silently retained by shutdown.
        var firstError: (any Error)?
        for context in values {
            do { try await close(context) } catch { firstError = firstError ?? error }
        }
        deletingProjects.subtract(ids)
        if let firstError { throw firstError }
    }

    private func acquire(_ projectID: String) async throws -> ProjectPersistenceContext {
        guard !refusesNewOperations, closeTask == nil else {
            throw SlateSyncError(code: "PROJECT_RUNTIME_CLOSED", message: "项目运行时已关闭")
        }
        let id = try PersistenceIdentifiers.project(projectID)
        guard !deletingProjects.contains(id) else {
            throw SlateSyncError(code: "PROJECT_DELETING", message: "项目正在删除")
        }
        let project = try await library.getProject(id, allowArchived: false)
        let libraryPath = try await library.libraryInfo().path
        // The Library lookups above release this actor. Shutdown may complete
        // while they are in flight, so recheck the terminal state before a
        // context or lease can be published after close() has returned.
        guard !refusesNewOperations, closeTask == nil else {
            throw SlateSyncError(code: "PROJECT_RUNTIME_CLOSED", message: "项目运行时已关闭")
        }
        guard !deletingProjects.contains(id) else {
            throw SlateSyncError(code: "PROJECT_DELETING", message: "项目正在删除")
        }
        let context: ProjectPersistenceContext
        if var existing = contexts[id] {
            existing.project = project
            contexts[id] = existing
            context = existing
        } else {
            let directory = URL(fileURLWithPath: libraryPath)
                .appending(path: project.relativePath, directoryHint: .isDirectory)
                .standardizedFileURL
            context = try ProjectPersistenceContext(
                project: project,
                tasks: ProjectTaskStore(projectDirectory: directory, writer: writer),
                scenarios: ScenarioStore(projectDirectory: directory),
                diagnostics: DiagnosticsStore(projectDirectory: directory, writer: writer)
            )
            contexts[id] = context
        }
        activeLeases[id, default: 0] += 1
        return context
    }

    private func release(_ projectID: String) {
        guard let count = activeLeases[projectID] else { return }
        if count > 1 {
            activeLeases[projectID] = count - 1
            return
        }
        activeLeases.removeValue(forKey: projectID)
        let waiters = leaseWaiters.removeValue(forKey: projectID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForLeases(of projectID: String) async {
        guard activeLeases[projectID, default: 0] > 0 else { return }
        await withCheckedContinuation { continuation in
            leaseWaiters[projectID, default: []].append(continuation)
        }
    }

    private func beginProjectTransition(_ projectID: String) throws {
        guard !deletingProjects.contains(projectID) else {
            throw SlateSyncError(code: "PROJECT_DELETING", message: "项目正在删除或关闭")
        }
        deletingProjects.insert(projectID)
    }

    private func endProjectTransition(_ projectID: String) {
        deletingProjects.remove(projectID)
        guard deletingProjects.isEmpty else { return }
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForProjectTransitions() async {
        guard !deletingProjects.isEmpty else { return }
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
        }
    }

    private func close(_ context: ProjectPersistenceContext) async throws {
        // Close every owner even if one reports an error so deletion never
        // proceeds with a silently retained sibling connection.
        var firstError: (any Error)?
        do { try await context.tasks.close() } catch { firstError = error }
        do { try await context.scenarios.close() } catch { firstError = firstError ?? error }
        do { try await context.diagnostics.close() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

}
