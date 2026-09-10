// Diagnostic session capture and persistence.
//
// Diagnostic sessions are stored beside tasks in the owning project.sqlite so
// project backups keep their evidence together. A JSON snapshot remains as a
// compatibility export and contains the same sanitized diagnostic payload.
import { join } from "node:path";
import { createHash } from "node:crypto";
import {
  closeSlateDatabase,
  migrateJsonDirectory,
  openSlateDatabase,
  readAppMetaMarker,
  removeJsonSnapshot,
  SQLITE_FILENAMES,
  writeAppMetaMarker,
  writeJsonSnapshot,
} from "./sqlite-store.mjs";

const MAX_DIAGNOSTIC_SESSIONS = 20;

// 一次性迁移的完成标记键；语义与 task-store 的同名机制一致。
const MIGRATION_MARKER_KEY = "json_migration_diagnostics_v1";

export function createDiagnosticsStore(baseDir, options = {}) {
  const sessionsDir = join(baseDir, "diagnostics");
  // options.db 注入时复用项目运行时的共享句柄；本 store 不拥有连接，
  // close() 只等待迁移完成，由句柄持有者统一关闭。
  const owned = !options.db;
  const { db, dbPath } = owned
    ? openSlateDatabase(baseDir, { kind: "project", filename: options.filename })
    : {
        db: options.db,
        dbPath: join(baseDir, options.filename || SQLITE_FILENAMES.legacy),
      };
  const ready = (async () => {
    // 完成标记命中直接返回，省去 readdir + 全量 JSON.parse 的重复成本。
    if (readAppMetaMarker(db, MIGRATION_MARKER_KEY)) return 0;
    const imported = await migrateJsonDirectory({
      db,
      directoryPath: sessionsDir,
      table: "diagnostic_sessions",
      timestampColumn: "saved_at",
      parseRecord(value, fallbackId) {
        const id = validateId(value?.id || fallbackId);
        const savedAt = value.savedAt || new Date(0).toISOString();
        return {
          id,
          dataJson: JSON.stringify({ ...value, id }),
          timestamp: savedAt,
        };
      },
    });
    writeAppMetaMarker(db, MIGRATION_MARKER_KEY, {
      imported,
      markedAt: new Date().toISOString(),
    });
    return imported;
  })();

  const store = {
    sessionsDir,
    dbPath,

    async saveSession(session) {
      await ready;
      const id = session.id ? validateId(session.id) : generateId();
      const savedAt = new Date().toISOString();
      const data = { ...session, id, savedAt };
      db.prepare(`
        INSERT INTO diagnostic_sessions (id, data_json, saved_at)
        VALUES (@id, @dataJson, @savedAt)
        ON CONFLICT(id) DO UPDATE SET
          data_json = excluded.data_json,
          saved_at = excluded.saved_at
      `).run({
        id,
        dataJson: JSON.stringify(data),
        savedAt,
      });
      await writeJsonSnapshot(sessionsDir, id, data);
      await pruneSessions();
      return id;
    },

    async loadSession(id) {
      await ready;
      const sessionId = validateId(id);
      const row = db.prepare(
        "SELECT data_json FROM diagnostic_sessions WHERE id = ?",
      ).get(sessionId);
      if (!row) {
        const error = new Error("诊断会话不存在");
        error.code = "ENOENT";
        throw error;
      }
      return JSON.parse(row.data_json);
    },

    async listSessions() {
      await ready;
      const rows = db.prepare(`
        SELECT data_json FROM diagnostic_sessions ORDER BY saved_at DESC
      `).all();
      const sessions = [];
      for (const row of rows) {
        try {
          const data = JSON.parse(row.data_json);
          sessions.push({
            id: data.id,
            filename: data.filename,
            provider: data.provider,
            model: data.model,
            pageCount: data.pageCount,
            recordCount: data.result?.records?.length ?? 0,
            durationMs: data.durationMs,
            savedAt: data.savedAt,
          });
        } catch {
          // Ignore malformed rows while keeping the diagnostics index usable.
        }
      }
      return sessions;
    },

    async deleteSession(id) {
      await ready;
      const sessionId = validateId(id);
      const result = db.prepare(
        "DELETE FROM diagnostic_sessions WHERE id = ?",
      ).run(sessionId);
      if (!result.changes) {
        const error = new Error("诊断会话不存在");
        error.code = "ENOENT";
        throw error;
      }
      await removeJsonSnapshot(sessionsDir, sessionId);
    },

    async getSessionDir() {
      return sessionsDir;
    },

    async close() {
      await ready;
      // 注入句柄的 store 不拥有连接；关闭动作由共享句柄的持有者执行一次。
      if (owned) closeSlateDatabase(db);
    },
  };

  async function pruneSessions() {
    const rows = db.prepare(`
      SELECT id FROM diagnostic_sessions
      ORDER BY saved_at DESC
      LIMIT -1 OFFSET ?
    `).all(MAX_DIAGNOSTIC_SESSIONS);
    if (!rows.length) return;
    const remove = db.transaction((ids) => {
      const statement = db.prepare(
        "DELETE FROM diagnostic_sessions WHERE id = ?",
      );
      for (const id of ids) statement.run(id);
    });
    remove(rows.map((row) => row.id));
    await Promise.all(rows.map((row) => removeJsonSnapshot(sessionsDir, row.id)));
  }

  return store;
}

export function createSessionCapture() {
  const session = {
    id: generateId(),
    startedAt: new Date().toISOString(),
    filename: null,
    provider: null,
    model: null,
    pageCount: 0,
    ocr: null,
    pages: [],
    scenario: null,
    result: null,
    durationMs: 0,
    usage: null,
    error: null,
  };

  return {
    session,

    setRequestInfo({ filename, provider, model, pageCount }) {
      session.filename = filename;
      session.provider = provider;
      session.model = model;
      session.pageCount = pageCount;
    },

    setOcrResult(ocrSummary, ocrRaw) {
      session.ocr = {
        summary: ocrSummary,
        pages: (ocrRaw?.pages || []).map((page) => ({
          pageNumber: page.pageNumber,
          views: (page.views || []).map((view) => ({
            viewIndex: view.viewIndex,
            viewType: view.viewType,
            width: view.width,
            height: view.height,
            blockCount: view.blocks?.length ?? 0,
            blocks: (view.blocks || []).map((block) => ({
              order: block.order,
              text: block.text,
              confidence: block.confidence,
              bboxNormalized: block.bboxNormalized,
            })),
            truncated: Boolean(view.truncated),
          })),
        })),
      };
    },

    addPageResult(pageNumber, stage, { request, response, result, ocrEvidence }) {
      let page = session.pages.find((p) => p.pageNumber === pageNumber);
      if (!page) {
        page = { pageNumber, stages: [] };
        session.pages.push(page);
      }
      page.stages.push({
        stage,
        timestamp: new Date().toISOString(),
        request: sanitizeRequest(request),
        response: sanitizeResponse(response),
        result,
        ocrEvidence: ocrEvidence || null,
      });
    },

    setFinalResult(output) {
      // Keep the selected/matched Profile ID with the diagnostic evidence so
      // later quality reviews can distinguish layout drift from OCR errors.
      session.scenario = output.scenario || null;
      session.result = output.result;
      session.durationMs = output.durationMs;
      session.usage = output.usage;
    },

    setError(error) {
      session.error = {
        message: error.message,
        status: error.status,
        stack: error.stack?.split("\n").slice(0, 10).join("\n"),
      };
    },
  };
}

function sanitizeRequest(request) {
  if (!request) return null;
  const sanitized = { ...request };
  if (sanitized.imageDataUrls) {
    sanitized.imageDataUrls = sanitized.imageDataUrls.map(
      (url) => `data:image/... (${Math.round(url.length / 1024)} KB)`,
    );
  }
  return sanitized;
}

function sanitizeResponse(response) {
  if (!response) return null;
  return {
    text: response.text,
    usage: response.usage || null,
    cost: response.cost ?? null,
  };
}

function generateId() {
  const hash = createHash("sha256")
    .update(`${Date.now()}-${Math.random()}`)
    .digest("hex");
  return hash.slice(0, 12);
}

function validateId(id) {
  const value = String(id || "");
  if (!/^[a-zA-Z0-9_-]+$/.test(value)) {
    throw new Error("无效诊断会话 ID");
  }
  return value;
}
