// Diagnostic session capture and persistence.
//
// createSessionCapture builds an in-memory record of one recognition run
// (request, per-page stages, OCR evidence, result, usage, error), while
// createDiagnosticsStore persists sessions as JSON under <data>/diagnostics
// with atomic writes and a bounded prune to the most recent sessions.
import {
  writeFile,
  mkdir,
  readFile,
  readdir,
  unlink,
  rename,
} from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";

const MAX_DIAGNOSTIC_SESSIONS = 20;

export function createDiagnosticsStore(baseDir) {
  const sessionsDir = join(baseDir, "diagnostics");

  return {
    async saveSession(session) {
      await mkdir(sessionsDir, { recursive: true, mode: 0o700 });
      const id = session.id ? validateId(session.id) : generateId();
      const filePath = join(sessionsDir, `${id}.json`);
      const tempPath = `${filePath}.${generateId()}.tmp`;
      const data = { ...session, id, savedAt: new Date().toISOString() };
      await writeFile(tempPath, JSON.stringify(data, null, 2), {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(tempPath, filePath);
      await pruneSessions(sessionsDir);
      return id;
    },

    async loadSession(id) {
      const filePath = join(sessionsDir, `${validateId(id)}.json`);
      const raw = await readFile(filePath, "utf8");
      return JSON.parse(raw);
    },

    async listSessions() {
      try {
        const files = await readdir(sessionsDir);
        const sessions = [];
        for (const file of files.filter((f) => f.endsWith(".json"))) {
          try {
            const raw = await readFile(join(sessionsDir, file), "utf8");
            const data = JSON.parse(raw);
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
            // skip corrupted files
          }
        }
        return sessions.sort((a, b) => (b.savedAt || "").localeCompare(a.savedAt || ""));
      } catch {
        return [];
      }
    },

    async deleteSession(id) {
      const filePath = join(sessionsDir, `${validateId(id)}.json`);
      await unlink(filePath);
    },

    async getSessionDir() {
      return sessionsDir;
    },
  };
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
  // Remove image data to keep diagnostic files manageable
  if (sanitized.imageDataUrls) {
    sanitized.imageDataUrls = sanitized.imageDataUrls.map(
      (url) => `data:image/... (${Math.round(url.length / 1024)} KB)`,
    );
  }
  if (sanitized.pdfDataUrl) {
    sanitized.pdfDataUrl = `data:application/pdf;... (${Math.round(sanitized.pdfDataUrl.length / 1024)} KB)`;
  }
  // Keep system prompt and user instruction
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

async function pruneSessions(dir) {
  try {
    const files = await readdir(dir);
    const jsonFiles = files.filter((f) => f.endsWith(".json"));
    if (jsonFiles.length <= MAX_DIAGNOSTIC_SESSIONS) return;

    const withStats = await Promise.all(
      jsonFiles.map(async (file) => {
        const filePath = join(dir, file);
        const raw = await readFile(filePath, "utf8").catch(() => null);
        const savedAt = raw ? JSON.parse(raw)?.savedAt || "" : "";
        return { file, filePath, savedAt };
      }),
    );
    withStats.sort((a, b) => (a.savedAt || "").localeCompare(b.savedAt || ""));

    const toDelete = withStats.slice(0, withStats.length - MAX_DIAGNOSTIC_SESSIONS);
    for (const { filePath } of toDelete) {
      await unlink(filePath).catch(() => {});
    }
  } catch {
    // pruning is best-effort
  }
}
