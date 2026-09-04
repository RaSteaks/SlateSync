import Foundation
import SlateSyncDomain

/// Stores already-normalized Scenario Profiles. Layout learning and similarity
/// belong to SM-05; SM-04 owns their exact v1 SQLite rows and project isolation.
public actor ScenarioStore {
    private let database: SQLiteDatabase
    private var didBootstrap = false
    private var bootstrapTask: Task<Void, any Error>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(projectDirectory: URL) throws {
        database = try SQLiteDatabase(
            url: projectDirectory.appending(path: SQLiteV1.projectDatabaseFilename)
        )
    }

    public func listProfiles() async throws -> [ScenarioSummary] {
        try await bootstrap()
        return try await database.rows(
            """
            SELECT id, profile_json, sample_count, created_at, updated_at, last_used_at
            FROM scenario_profiles ORDER BY last_used_at DESC;
            """
        ).compactMap { row in
            guard
                let id = row["id"] ?? nil,
                let json = row["profile_json"] ?? nil,
                let data = json.data(using: .utf8),
                let profile = try? decoder.decode(ScenarioProfile.self, from: data),
                let sampleCount = Int((row["sample_count"] ?? nil) ?? ""),
                let createdAt = row["created_at"] ?? nil,
                let updatedAt = row["updated_at"] ?? nil,
                let lastUsedAt = row["last_used_at"] ?? nil
            else { return nil }
            return ScenarioSummary(
                id: id,
                label: profile.label,
                fingerprint: profile.fingerprint,
                fingerprintVersion: profile.fingerprintVersion,
                schemaVersion: profile.schemaVersion,
                sampleCount: sampleCount,
                fieldCount: 10,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastUsedAt: lastUsedAt
            )
        }
    }

    public func getProfile(_ id: String) async throws -> ScenarioData {
        try await bootstrap()
        let scenarioID = try PersistenceIdentifiers.scenario(id)
        guard let row = try await database.rows(
            "SELECT * FROM scenario_profiles WHERE id = ?;",
            bindings: [scenarioID]
        ).first else {
            throw SlateSyncError(code: "ENOENT", message: "场记结构不存在")
        }
        return try scenarioData(row)
    }

    public func importProfile(_ profile: ScenarioProfile) async throws -> ScenarioData {
        try await bootstrap()
        if let row = try await database.rows(
            "SELECT * FROM scenario_profiles WHERE fingerprint_version = ? AND fingerprint = ?;",
            bindings: [String(profile.fingerprintVersion), profile.fingerprint]
        ).first {
            return try scenarioData(row)
        }
        let id = "scenario-\(PersistenceJSON.sha256Prefix(profile.fingerprint, count: 16))"
        let now = PersistenceJSON.timestamp()
        let profileJSON = try PersistenceJSON.string(
            from: encoder.encode(profile),
            errorCode: "SCENARIO_INVALID"
        )
        try await database.execute(
            """
            INSERT INTO scenario_profiles
              (id, schema_version, fingerprint_version, fingerprint, profile_json,
               sample_count, created_at, updated_at, last_used_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(fingerprint_version, fingerprint) DO NOTHING;
            """,
            bindings: [
                id,
                String(profile.schemaVersion),
                String(profile.fingerprintVersion),
                profile.fingerprint,
                profileJSON,
                now,
                now,
                now,
            ]
        )
        // A concurrent import of the same normalized profile is idempotent:
        // whichever insert wins supplies the shared canonical row.
        guard let stored = try await database.rows(
            "SELECT * FROM scenario_profiles WHERE fingerprint_version = ? AND fingerprint = ?;",
            bindings: [String(profile.fingerprintVersion), profile.fingerprint]
        ).first else {
            throw SlateSyncError(code: "SCENARIO_INVALID", message: "场记结构导入失败")
        }
        return try scenarioData(stored)
    }

    /// Applies an SM-05 match as one v1 transaction. The profile row, sample
    /// count and observation cannot diverge after cancellation or SQL failure.
    public func applyScenarioMatch(
        candidate: ScenarioProfile,
        selectedProfileID: String?,
        observationPayload: Data
    ) async throws -> ScenarioMatchCommit {
        try await bootstrap()
        try Task.checkCancellation()
        let now = PersistenceJSON.timestamp()
        let profileJSON = try PersistenceJSON.string(from: encoder.encode(candidate), errorCode: "SCENARIO_INVALID")
        let observationJSON = try PersistenceJSON.string(from: observationPayload, errorCode: "SCENARIO_INVALID")
        let candidateID = "scenario-\(PersistenceJSON.sha256Prefix(candidate.fingerprint, count: 16))"
        let targetID = try selectedProfileID.map(PersistenceIdentifiers.scenario) ?? candidateID
        let observationID = "observation-\(PersistenceJSON.sha256Prefix("\(targetID):\(now):\(UUID())", count: 16))"
        var commands: [SQLiteCommand] = []
        if selectedProfileID == nil {
            commands.append(SQLiteCommand(
                """
                INSERT INTO scenario_profiles
                  (id, schema_version, fingerprint_version, fingerprint, profile_json,
                   sample_count, created_at, updated_at, last_used_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(fingerprint_version, fingerprint) DO NOTHING;
                """,
                bindings: [candidateID, String(candidate.schemaVersion), String(candidate.fingerprintVersion), candidate.fingerprint, profileJSON, now, now, now]
            ))
        }
        commands.append(SQLiteCommand(
            "UPDATE scenario_profiles SET sample_count = sample_count + 1, updated_at = ?, last_used_at = ? WHERE id = ?;",
            bindings: [now, now, targetID]
        ))
        commands.append(SQLiteCommand(
            """
            INSERT INTO scenario_observations
              (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [observationID, targetID, String(candidate.fingerprintVersion), candidate.fingerprint, observationJSON, now]
        ))
        try await database.transaction(commands)
        return ScenarioMatchCommit(profile: try await getProfile(targetID), observationID: observationID)
    }

    /// Persists an SM-05-produced observation and updates the selected profile
    /// atomically, matching the v1 scenario store's reuse transaction.
    @discardableResult
    public func recordObservation(
        profileID: String,
        fingerprintVersion: Int,
        fingerprint: String,
        payload: Data,
        incrementSampleCount: Bool = true
    ) async throws -> String {
        try await bootstrap()
        let id = try PersistenceIdentifiers.scenario(profileID)
        _ = try await getProfile(id)
        let now = PersistenceJSON.timestamp()
        let observationID = "observation-\(PersistenceJSON.sha256Prefix("\(id):\(now):\(UUID())", count: 16))"
        let json = try PersistenceJSON.string(from: payload, errorCode: "SCENARIO_INVALID")
        let increment = incrementSampleCount ? 1 : 0
        try await database.transaction([
            SQLiteCommand(
                """
                UPDATE scenario_profiles
                SET sample_count = sample_count + ?, last_used_at = ?, updated_at = ?
                WHERE id = ?;
                """,
                bindings: [String(increment), now, now, id]
            ),
            SQLiteCommand(
                """
                INSERT INTO scenario_observations
                  (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [observationID, id, String(fingerprintVersion), fingerprint, json, now]
            ),
        ])
        return observationID
    }

    public func close() async throws {
        try await database.close()
    }

    private func bootstrap() async throws {
        guard !didBootstrap else { return }
        if let bootstrapTask {
            try await bootstrapTask.value
            return
        }
        // Publish schema initialization before its SQLite await so parallel
        // first-use imports cannot run multiple bootstrap sequences.
        let task = Task<Void, any Error> { try await self.performBootstrap() }
        bootstrapTask = task
        do {
            try await task.value
            didBootstrap = true
            bootstrapTask = nil
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    private func performBootstrap() async throws {
        try await SQLiteV1.bootstrapProject(database)
    }

    private func scenarioData(_ row: [String: String?]) throws -> ScenarioData {
        guard
            let id = row["id"] ?? nil,
            let json = row["profile_json"] ?? nil,
            let data = json.data(using: .utf8),
            let sampleCount = Int((row["sample_count"] ?? nil) ?? ""),
            let createdAt = row["created_at"] ?? nil,
            let updatedAt = row["updated_at"] ?? nil,
            let lastUsedAt = row["last_used_at"] ?? nil
        else {
            throw SlateSyncError(code: "SCENARIO_INVALID", message: "场记结构记录不完整")
        }
        do {
            return ScenarioData(
                id: id,
                profile: try decoder.decode(ScenarioProfile.self, from: data),
                sampleCount: sampleCount,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastUsedAt: lastUsedAt
            )
        } catch let error as SlateSyncError {
            throw error
        } catch {
            throw SlateSyncError(code: "SCENARIO_INVALID", message: "场记结构 JSON 无效")
        }
    }
}
