// Persistent Scenario Profile store.
//
// Profiles are immutable structure snapshots inside one project.sqlite.
// Matching updates usage metadata and records an observation, while a changed
// layout creates a new profile without sharing rows with another project.
import { createHash } from "node:crypto";
import { join } from "node:path";
import {
  DEFAULT_SCENARIO_MATCHING,
  normalizeScenarioProfile,
  publicScenarioProfile,
  scenarioSimilarity,
} from "./profile.mjs";
import { closeSlateDatabase, openSlateDatabase } from "../sqlite-store.mjs";

export function createScenarioStore(baseDir, options = {}) {
  const { db, dbPath } = openSlateDatabase(baseDir, {
    kind: "project",
    filename: options.filename,
  });
  const matchingSource = options.matching;

  const store = {
    dbPath,

    async listProfiles() {
      const rows = db.prepare(`
        SELECT id, profile_json, sample_count, created_at, updated_at, last_used_at
        FROM scenario_profiles
        ORDER BY last_used_at DESC
      `).all();
      return rows.map((row) => profileSummary(row));
    },

    async getProfile(id) {
      const row = db.prepare(
        "SELECT * FROM scenario_profiles WHERE id = ?",
      ).get(validateId(id));
      if (!row) {
        const error = new Error("场记结构不存在");
        error.code = "ENOENT";
        throw error;
      }
      return profileRecord(row);
    },

    async matchAndSave(observation, options = {}) {
      const candidate = normalizeScenarioProfile(observation, options);
      // Resolve matching settings per observation so hot-reloaded workflow
      // configuration applies to each Electron recognition request.
      const matching = {
        ...DEFAULT_SCENARIO_MATCHING,
        ...(await resolveMatching(matchingSource)),
        ...(await resolveMatching(options.matching)),
      };
      const rows = db.prepare(
        "SELECT * FROM scenario_profiles ORDER BY last_used_at DESC",
      ).all();
      const scored = rows
        .map((row) => ({ row, score: scenarioSimilarity(candidate, JSON.parse(row.profile_json)) }))
        .sort((left, right) => right.score - left.score);
      const best = scored[0] || null;
      const second = scored[1] || null;
      const confident = Boolean(
        best &&
        best.score >= Number(matching.threshold) &&
        (!second || best.score - second.score >= Number(matching.ambiguityMargin)),
      );
      const now = new Date().toISOString();
      let profileId;
      let match;
      let score = best?.score || 0;

      const transaction = db.transaction(() => {
        if (confident) {
          profileId = best.row.id;
          match = "reused";
          db.prepare(`
            UPDATE scenario_profiles
            SET sample_count = sample_count + 1,
                last_used_at = ?,
                updated_at = ?
            WHERE id = ?
          `).run(now, now, profileId);
        } else {
          profileId = createProfileId(candidate.fingerprint);
          match = "created";
          const profile = {
            ...candidate,
            output: candidate.output || options.output || undefined,
          };
          db.prepare(`
            INSERT INTO scenario_profiles
              (id, schema_version, fingerprint_version, fingerprint, profile_json,
               sample_count, created_at, updated_at, last_used_at)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
          `).run(
            profileId,
            profile.schemaVersion,
            profile.fingerprintVersion,
            profile.fingerprint,
            JSON.stringify(profile),
            now,
            now,
            now,
          );
          score = 1;
        }
        const observationId = createObservationId(profileId, now);
        db.prepare(`
          INSERT INTO scenario_observations
            (id, profile_id, fingerprint_version, fingerprint, observation_json, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
        `).run(
          observationId,
          profileId,
          candidate.fingerprintVersion,
          candidate.fingerprint,
          JSON.stringify({ ...candidate, matchedScore: score, match }),
          now,
        );
        return observationId;
      });
      const observationId = transaction();
      const profile = await store.getProfile(profileId);
      return {
        profile,
        observationId,
        match,
        score: Number(score.toFixed(6)),
        ambiguous: Boolean(best && !confident && best.score >= Number(matching.threshold)),
      };
    },

    async importProfile(value) {
      const profile = normalizeScenarioProfile(value);
      const existing = db.prepare(`
        SELECT * FROM scenario_profiles
        WHERE fingerprint_version = ? AND fingerprint = ?
      `).get(profile.fingerprintVersion, profile.fingerprint);
      if (existing) return profileRecord(existing);
      const now = new Date().toISOString();
      const id = createProfileId(profile.fingerprint);
      db.prepare(`
        INSERT INTO scenario_profiles
          (id, schema_version, fingerprint_version, fingerprint, profile_json,
           sample_count, created_at, updated_at, last_used_at)
        VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
      `).run(
        id,
        profile.schemaVersion,
        profile.fingerprintVersion,
        profile.fingerprint,
        JSON.stringify(profile),
        now,
        now,
        now,
      );
      return store.getProfile(id);
    },

    async close() {
      closeSlateDatabase(db);
    },
  };

  return store;
}

async function resolveMatching(source) {
  if (typeof source === "function") {
    return (await source()) || {};
  }
  return source || {};
}

function profileRecord(row) {
  return {
    id: row.id,
    ...publicScenarioProfile(JSON.parse(row.profile_json)),
    sampleCount: Number(row.sample_count) || 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastUsedAt: row.last_used_at,
  };
}

function profileSummary(row) {
  const profile = JSON.parse(row.profile_json);
  return {
    id: row.id,
    label: profile.label,
    fingerprint: profile.fingerprint,
    fingerprintVersion: profile.fingerprintVersion,
    schemaVersion: profile.schemaVersion,
    sampleCount: Number(row.sample_count) || 0,
    fieldCount: Object.keys(profile.fields || {}).length,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastUsedAt: row.last_used_at,
  };
}

function createProfileId(fingerprint) {
  return `scenario-${createHash("sha256").update(String(fingerprint)).digest("hex").slice(0, 16)}`;
}

function createObservationId(profileId, timestamp) {
  return `observation-${createHash("sha256")
    .update(`${profileId}:${timestamp}:${Math.random()}`)
    .digest("hex")
    .slice(0, 16)}`;
}

function validateId(id) {
  const value = String(id || "");
  if (!/^scenario-[a-f0-9]{16}$/.test(value)) {
    throw new Error("无效场记结构 ID");
  }
  return value;
}
