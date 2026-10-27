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
        // Preserve the legacy projection's tolerance of unreadable imported
        // rows; direct lookup still reports their error instead of hiding it.
        let values = try await database.rows("SELECT * FROM scenario_profiles ORDER BY last_used_at DESC;").compactMap { try? scenarioData($0) }
        var index: [String: ScenarioData] = [:]
        for value in values {
            guard index.updateValue(value, forKey: value.id) == nil else { throw mergeConflict }
        }
        var aliases: [String: [String]] = [:]
        for value in values where value.canonicalID != nil {
            var current = value, visited = Set<String>()
            while let target = current.canonicalID {
                guard visited.insert(current.id).inserted, let next = index[target] else { throw mergeConflict }
                current = next
            }
            aliases[current.id, default: []].append(value.id)
        }
        return values.filter { $0.canonicalID == nil }.map { value in
            .init(id: value.id, label: value.label, fingerprint: value.fingerprint, fingerprintVersion: value.fingerprintVersion,
                  schemaVersion: value.schemaVersion, sampleCount: value.sampleCount, fieldCount: 10,
                  createdAt: value.createdAt, updatedAt: value.updatedAt, lastUsedAt: value.lastUsedAt,
                  aliases: aliases[value.id]?.sorted())
        }
    }

    public func getProfile(_ id: String) async throws -> ScenarioData {
        try await bootstrap()
        var currentID = id, visited = Set<String>()
        while visited.insert(currentID).inserted {
            let scenarioID = try PersistenceIdentifiers.scenario(currentID)
            guard let row = try await database.rows("SELECT * FROM scenario_profiles WHERE id = ?;", bindings: [scenarioID]).first else {
                throw SlateSyncError(code: "ENOENT", message: "场记结构不存在")
            }
            let profile = try scenarioData(row)
            guard let canonical = profile.canonicalID else { return profile }
            currentID = canonical
        }
        throw mergeConflict
    }

    /// One read owns the entire matching snapshot. Reading each profile through
    /// separate project leases would mix revisions and reopen encrypted storage.
    public func snapshot() async throws -> ScenarioMatchingSnapshot {
        try await bootstrap()
        // One compound read keeps aliases and observations on the same SQLite
        // snapshot, without repeating large profile JSON for every observation.
        let rows = try await database.rows("""
            SELECT 'profile' AS kind, id, profile_json, sample_count, created_at, updated_at, last_used_at
            FROM scenario_profiles
            UNION ALL
            SELECT 'observation', profile_id, observation_json, NULL, created_at, NULL, NULL
            FROM scenario_observations
            WHERE profile_id IS NOT NULL AND fingerprint_version = 2
              AND id NOT GLOB 'observation-confirm-*' AND id NOT GLOB 'observation-merge-*'
            ORDER BY created_at, id;
            """)
        let profiles = rows.filter { ($0["kind"] ?? nil) == "profile" }.compactMap { try? scenarioData($0) }
        let index = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var associations = Set<ScenarioConfirmedAssociation>()
        for row in rows where (row["kind"] ?? nil) == "observation" {
            guard let profileID = row["id"] ?? nil, var profile = index[profileID],
                  let text = row["profile_json"] ?? nil,
                  let observation = try? decoder.decode(ScenarioLearningObservation.self, from: Data(text.utf8)),
                  [.candidate, .ambiguous].contains(observation.decision.status),
                  let candidate = observation.decision.candidate,
                  candidate.schemaVersion == 1, candidate.fingerprintVersion == 2,
                  let structure = candidate.structure, structure.version == 2 else { continue }
            // Only confirmCandidate attaches these formerly pending decisions.
            // Automatic .reused observations never grow the matching evidence.
            // Resolve at read time so merge and undo immediately change routing.
            var visited = Set<String>()
            while let canonical = profile.canonicalID {
                guard visited.insert(profile.id).inserted, let next = index[canonical] else { throw mergeConflict }
                profile = next
            }
            associations.insert(.init(profileID: profile.id, structure: structure))
        }
        // The matcher sorts each family's alternatives before scoring, so Set
        // iteration order cannot affect ties or diagnostics.
        return .init(profiles: profiles.filter { $0.canonicalID == nil }, confirmedAssociations: Array(associations))
    }

    public func previewMerge(sourceID: String, targetID: String) async throws -> ScenarioMergePreview {
        let source = try await getProfile(sourceID), target = try await getProfile(targetID)
        guard source.id != target.id else { throw mergeConflict }
        var warnings: [String] = []
        if source.output != target.output { warnings.append("输出配置不同，已有记录保留原配置，当前项目设置不变") }
        if source.recognition.promptHints != target.recognition.promptHints { warnings.append("识别说明不同，合并后采用目标版式说明") }
        if source.structure == nil || target.structure == nil { warnings.append("部分旧版式缺少结构信息，请核对原稿后确认") }
        else if source.structure != target.structure { warnings.append("表头位置存在差异，请确认属于同一版式") }
        return .init(source: source, target: target, warnings: warnings)
    }

    public func merge(_ preview: ScenarioMergePreview) async throws -> ScenarioMergeReceipt {
        try await bootstrap()
        guard preview.source.id != preview.target.id,
              let sourceRow = try await database.rows("SELECT * FROM scenario_profiles WHERE id = ?;", bindings: [preview.source.id]).first,
              let targetRow = try await database.rows("SELECT * FROM scenario_profiles WHERE id = ?;", bindings: [preview.target.id]).first,
              let before = sourceRow["profile_json"] ?? nil, let targetJSON = targetRow["profile_json"] ?? nil else { throw mergeConflict }
        let source = try scenarioData(sourceRow), target = try scenarioData(targetRow)
        guard source.canonicalID == nil, target.canonicalID == nil,
              source.profile == preview.source.profile, target.profile == preview.target.profile else { throw mergeConflict }
        // Patch only the routing field; an older/future producer may have
        // additional JSON keys that the typed projection does not understand.
        var alias = try PersistenceJSON.object(from: Data(before.utf8), errorCode: "SCENARIO_INVALID")
        alias["canonicalID"] = target.id
        let after = try PersistenceJSON.string(from: PersistenceJSON.data(from: alias, errorCode: "SCENARIO_INVALID"), errorCode: "SCENARIO_INVALID")
        let receipt = ScenarioMergeReceipt(id: "observation-merge-\(UUID().uuidString.lowercased())",
            sourceID: source.id, targetID: target.id, sourceLabel: source.label, targetLabel: target.label)
        let event = MergeEvent(receipt: receipt, before: before, after: after, undone: false)
        let payload = try PersistenceJSON.string(from: encoder.encode(event), errorCode: "SCENARIO_INVALID")
        let now = PersistenceJSON.timestamp()
        try Task.checkCancellation()
        // Both compared profiles must still match the preview. Keeping the old
        // row as an alias preserves all task/observation references and enables undo.
        let changes = try await database.transaction([
            .init("UPDATE scenario_profiles SET profile_json = ?, updated_at = ? WHERE id = ? AND profile_json = ? AND EXISTS (SELECT 1 FROM scenario_profiles WHERE id = ? AND profile_json = ?);",
                  bindings: [after, now, source.id, before, target.id, targetJSON]),
            .init("INSERT INTO scenario_observations (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at) SELECT ?, ?, ?, ?, ?, ? WHERE changes() = 1;",
                  bindings: [receipt.id, source.id, String(source.fingerprintVersion), source.fingerprint, payload, now]),
        ])
        guard changes.first == 1 else { throw mergeConflict }
        return receipt
    }

    public func latestMerge() async throws -> ScenarioMergeReceipt? {
        try await bootstrap()
        let rows = try await database.rows("SELECT o.observation_json, p.profile_json FROM scenario_observations o JOIN scenario_profiles p ON o.profile_id = p.id WHERE o.id GLOB 'observation-merge-*' ORDER BY o.created_at DESC, o.id DESC LIMIT 20;")
        for row in rows {
            guard let text = row["observation_json"] ?? nil else { continue }
            let event = try decoder.decode(MergeEvent.self, from: Data(text.utf8))
            if !event.undone, (row["profile_json"] ?? nil) == event.after { return event.receipt }
        }
        return nil
    }

    public func undoMerge(_ receiptID: String) async throws {
        try await bootstrap()
        guard let text = try await database.scalar("SELECT observation_json FROM scenario_observations WHERE id = ? AND id GLOB 'observation-merge-*';", bindings: [receiptID]) else { throw mergeConflict }
        var event = try decoder.decode(MergeEvent.self, from: Data(text.utf8))
        guard !event.undone else { throw mergeConflict }
        event.undone = true
        let payload = try PersistenceJSON.string(from: encoder.encode(event), errorCode: "SCENARIO_INVALID")
        try Task.checkCancellation()
        let changes = try await database.transaction([
            .init("UPDATE scenario_profiles SET profile_json = ?, updated_at = ? WHERE id = ? AND profile_json = ?;",
                  bindings: [event.before, PersistenceJSON.timestamp(), event.receipt.sourceID, event.after]),
            .init("UPDATE scenario_observations SET observation_json = ? WHERE id = ? AND changes() = 1;", bindings: [payload, receiptID]),
        ])
        guard changes.first == 1 else { throw mergeConflict }
    }

    private struct MergeEvent: Codable {
        let receipt: ScenarioMergeReceipt
        let before: String
        let after: String
        var undone: Bool
    }
    private var mergeConflict: SlateSyncError {
        .init(code: "SCENARIO_CONFLICT", message: "场记版式已变化或合并关系无效，请刷新后重试")
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

    public func saveObservation(_ observation: ScenarioLearningObservation) async throws {
        try await bootstrap()
        guard let candidate = observation.decision.candidate,
              candidate.fingerprintVersion == 2, candidate.structure?.version == 2 else { return }
        try Task.checkCancellation()
        let profileID = observation.decision.profile?.id
        // Digest excludes run IDs and filenames. Exact retries cannot inflate
        // sample counts; the existing nullable foreign key stores candidates.
        let id = "observation-" + PersistenceJSON.sha256Prefix(observation.sourceDigest, count: 32)
        let payload = try PersistenceJSON.string(from: encoder.encode(observation), errorCode: "SCENARIO_INVALID")
        let now = PersistenceJSON.timestamp()
        var commands = [SQLiteCommand(
            "INSERT INTO scenario_observations (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at) VALUES (?, ?, 2, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET profile_id=excluded.profile_id, fingerprint=excluded.fingerprint, observation_json=excluded.observation_json WHERE scenario_observations.profile_id IS NULL;",
            bindings: [id, profileID, candidate.fingerprint, payload, now])]
        if let profileID {
            commands.append(.init("UPDATE scenario_profiles SET sample_count = sample_count + 1, last_used_at = ?, updated_at = ? WHERE id = ? AND changes() = 1;",
                                  bindings: [now, now, profileID]))
        }
        // Keep the pending collection bounded without deleting confirmed or v1
        // evidence. Newest 100 distinct observations remain available for review.
        commands.append(.init("DELETE FROM scenario_observations WHERE profile_id IS NULL AND fingerprint_version = 2 AND id NOT IN (SELECT id FROM scenario_observations WHERE profile_id IS NULL AND fingerprint_version = 2 ORDER BY created_at DESC, id DESC LIMIT 100);"))
        try await database.transaction(commands)
    }

    public func listCandidates() async throws -> [ScenarioCandidate] {
        try await bootstrap()
        let rows = try await database.rows("SELECT id, observation_json FROM scenario_observations WHERE profile_id IS NULL AND fingerprint_version = 2 ORDER BY created_at, id;")
        var candidates: [String: ScenarioCandidate] = [:]
        for row in rows {
            guard let id = row["id"] ?? nil, let text = row["observation_json"] ?? nil else { continue }
            let observation = try decoder.decode(ScenarioLearningObservation.self, from: Data(text.utf8))
            guard observation.decision.status != .reused, let profile = observation.decision.candidate else { continue }
            let previous = candidates[profile.fingerprint]
            candidates[profile.fingerprint] = .init(id: previous?.id ?? id, profile: previous?.profile ?? profile,
                                                  sourceCount: (previous?.sourceCount ?? 0) + 1)
        }
        return candidates.values.sorted { $0.id < $1.id }
    }

    public func confirmCandidate(_ candidateID: String, label: String, existingProfileID: String?) async throws -> ScenarioData {
        try await bootstrap()
        let cleanedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingProfileID != nil || (!cleanedLabel.isEmpty && cleanedLabel.count <= 120) else {
            throw SlateSyncError(code: "SCENARIO_INVALID", message: "场记版式名称须为 1–120 个字符")
        }
        guard let row = try await database.rows("SELECT observation_json FROM scenario_observations WHERE id = ? AND profile_id IS NULL AND fingerprint_version = 2;", bindings: [candidateID]).first,
              let text = row["observation_json"] ?? nil,
              let proposed = try decoder.decode(ScenarioLearningObservation.self, from: Data(text.utf8)).decision.candidate,
              proposed.schemaVersion == 1, proposed.fingerprintVersion == 2, proposed.structure?.version == 2 else {
            throw SlateSyncError(code: "SCENARIO_NOT_FOUND", message: "场记版式候选已不存在，请刷新后重试")
        }
        // An exact candidate may refer to an already merged profile. Resolve its
        // canonical identity instead of resurrecting the hidden alias on retry.
        let exactID = try await database.scalar("SELECT id FROM scenario_profiles WHERE fingerprint_version = 2 AND fingerprint = ?;", bindings: [proposed.fingerprint])
        let old: ScenarioData?, oldJSON: String?
        if let selectedID = existingProfileID ?? exactID {
            let resolved = try await getProfile(selectedID)
            guard let row = try await database.rows("SELECT * FROM scenario_profiles WHERE id = ?;", bindings: [resolved.id]).first else { throw mergeConflict }
            let value = try scenarioData(row)
            guard value.canonicalID == nil else { throw mergeConflict }
            old = value; oldJSON = row["profile_json"] ?? nil
        } else { old = nil; oldJSON = nil }
        let profile = ScenarioProfile(schemaVersion: 1, fingerprintVersion: old?.fingerprintVersion ?? 2,
            fingerprint: old?.fingerprint ?? proposed.fingerprint, label: old?.label ?? cleanedLabel,
            layout: old?.layout ?? proposed.layout, fields: old?.fields ?? proposed.fields,
            recognition: old?.recognition ?? proposed.recognition,
            output: old?.output ?? proposed.output, structure: old?.structure ?? proposed.structure)
        let id = old?.id ?? "scenario-\(PersistenceJSON.sha256Prefix(profile.fingerprint, count: 16))"
        let now = PersistenceJSON.timestamp()
        let payload: String
        if let oldJSON {
            if old?.structure != nil { payload = oldJSON }
            else {
                var object = try PersistenceJSON.object(from: Data(oldJSON.utf8), errorCode: "SCENARIO_INVALID")
                object["structure"] = try JSONSerialization.jsonObject(with: encoder.encode(proposed.structure))
                payload = try PersistenceJSON.string(from: PersistenceJSON.data(from: object, errorCode: "SCENARIO_INVALID"), errorCode: "SCENARIO_INVALID")
            }
        } else { payload = try PersistenceJSON.string(from: encoder.encode(profile), errorCode: "SCENARIO_INVALID") }
        let audit = try PersistenceJSON.string(from: encoder.encode(ConfirmationEvent(candidateID: candidateID, before: oldJSON, after: payload)), errorCode: "SCENARIO_INVALID")
        try Task.checkCancellation()
        let changes = try await database.transaction([
            .init("INSERT INTO scenario_profiles (id, schema_version, fingerprint_version, fingerprint, profile_json, sample_count, created_at, updated_at, last_used_at) SELECT ?, 1, ?, ?, ?, 0, ?, ?, ? WHERE EXISTS (SELECT 1 FROM scenario_observations WHERE id = ? AND profile_id IS NULL) ON CONFLICT(id) DO UPDATE SET profile_json=excluded.profile_json, updated_at=excluded.updated_at WHERE scenario_profiles.profile_json = ?;",
                  bindings: [id, String(profile.fingerprintVersion), profile.fingerprint, payload, now, now, now, candidateID, oldJSON]),
            .init("UPDATE scenario_observations SET profile_id = ? WHERE profile_id IS NULL AND fingerprint_version = 2 AND fingerprint = ? AND changes() = 1;", bindings: [id, proposed.fingerprint]),
            .init("UPDATE scenario_profiles SET sample_count = sample_count + changes(), last_used_at = ? WHERE id = ? AND changes() > 0;", bindings: [now, id]),
            .init("INSERT INTO scenario_observations (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at) SELECT ?, ?, 2, ?, ?, ? WHERE changes() = 1;",
                  bindings: ["observation-confirm-\(UUID().uuidString.lowercased())", id, proposed.fingerprint, audit, now]),
        ])
        guard changes.first == 1 else { throw mergeConflict }
        return try await getProfile(id)
    }

    private struct ConfirmationEvent: Codable {
        let candidateID: String
        let before: String?
        let after: String
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
