// Local application logger for the Main process.
//
// Logs are plain-text daily files under <userData>/logs/slatesync-YYYY-MM-DD.log
// so they stay human-readable outside the app. The Main process is the single
// persistence writer: append writes are serialized through one promise chain,
// rotated by local calendar day, and pruned to a fixed retention window.
// Logging is strictly advisory — every failure (unwritable directory, disk
// errors) is swallowed after a single console warning so it can never break
// recognition, IPC handlers, or app lifecycle. readEntries parses the text
// back into structured entries (including recognition progress meta) for the
// in-app log viewer.
import { appendFile, mkdir, readdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_RETENTION_DAYS = 7;
const DEFAULT_READ_LIMIT = 500;
const MAX_READ_LIMIT = 2000;
// Level filtering uses a severity threshold: requesting "warn" keeps warn and
// error entries, matching what a reviewer means by "show me problems".
const LEVEL_SEVERITY = { info: 0, warn: 1, error: 2 };
const LOG_FILE_PATTERN = /^slatesync-(\d{4}-\d{2}-\d{2})\.log$/;
// Line shape: [local timestamp] [LEVEL] [category] message · key=value · …
// The level and category brackets are fixed-width so scanning stays cheap.
const LINE_PATTERN =
  /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] \[(INFO|WARN|ERROR)\] \[([a-z][a-z0-9-]*)\] (.*)$/;

// Structured meta keys that parseLogLine lifts out of the message tail. Only
// these keys are recognized so ordinary message text containing "·" or "=" is
// never mistaken for metadata; unknown trailing pairs stay part of the message.
const META_KEYS = new Set([
  "phase",
  "percent",
  "completed",
  "total",
  "completedViews",
  "totalViews",
  "viewIndex",
  "pageNumber",
  "cacheHit",
  "provider",
  "model",
  "pageCount",
  "records",
  "durationMs",
  "engine",
  "taskId",
]);
const NUMBER_KEYS = new Set([
  "percent",
  "completed",
  "total",
  "completedViews",
  "totalViews",
  "viewIndex",
  "pageNumber",
  "pageCount",
  "records",
  "durationMs",
]);

export function createAppLogger(userDataPath, options = {}) {
  const now = typeof options.now === "function" ? options.now : () => new Date();
  const retentionDays = Number.isFinite(options.retentionDays)
    ? Math.max(1, Math.trunc(options.retentionDays))
    : DEFAULT_RETENTION_DAYS;
  const logsDir = join(userDataPath, "logs");

  // Appends are serialized through one promise chain so concurrent callers
  // (lifecycle events plus a running recognition's progress stream) keep a
  // stable order inside each file. The chain never rejects: a failed append
  // is dropped after one console warning.
  let writeChain = Promise.resolve();
  let activeDay = null;
  let warnedWriteFailure = false;

  function enqueue(operation) {
    const run = writeChain.then(operation).catch(() => {
      if (!warnedWriteFailure) {
        warnedWriteFailure = true;
        console.warn("SlateSync 本地日志写入失败；后续失败将静默丢弃。");
      }
    });
    writeChain = run;
    return run;
  }

  function append(level, category, message, meta) {
    const date = now();
    const line = formatLine(date, level, category, message, meta);
    return enqueue(async () => {
      const day = dayKey(date);
      if (day !== activeDay) {
        activeDay = day;
        await mkdir(logsDir, { recursive: true, mode: 0o700 });
        await pruneOldFiles();
      }
      await appendFile(join(logsDir, `${LOG_FILE_PREFIX(day)}.log`), line, {
        mode: 0o600,
      });
    });
  }

  // Retention pruning runs on day rotation (and therefore on the first write
  // of a session). File dates come from the filename, not mtime, so clock
  // changes cannot resurrect or delete the wrong files.
  async function pruneOldFiles() {
    const cutoff = dayKey(
      shiftDays(now(), -(retentionDays - 1)),
    );
    const names = await readdir(logsDir).catch(() => []);
    await Promise.all(
      names
        .map((name) => ({ name, match: LOG_FILE_PATTERN.exec(name) }))
        .filter(({ match }) => match && match[1] < cutoff)
        .map(({ name }) => rm(join(logsDir, name), { force: true }).catch(() => {})),
    );
  }

  async function readEntries(request = {}) {
    // Wait for already-queued appends so a read right after a log call
    // observes it; appends racing the read land in the next poll instead.
    await writeChain;
    const limit = normalizeLimit(request.limit);
    const level = normalizeLevel(request.level);
    const category =
      typeof request.category === "string" && request.category && request.category !== "all"
        ? request.category
        : null;
    const names = await readdir(logsDir).catch(() => []);
    const days = names
      .map((name) => LOG_FILE_PATTERN.exec(name)?.[1])
      .filter(Boolean)
      .sort()
      .reverse();
    const matched = [];
    let hasMore = false;
    for (const day of days) {
      const content = await readFile(join(logsDir, `${LOG_FILE_PREFIX(day)}.log`), "utf8").catch(() => "");
      const lines = content.split("\n");
      // Lines are chronological within a file; scan newest-first so the
      // limit applies to the most recent activity across all retained days.
      for (let index = lines.length - 1; index >= 0; index--) {
        const entry = parseLogLine(lines[index]);
        if (!entry) continue;
        if (level && LEVEL_SEVERITY[entry.level] < LEVEL_SEVERITY[level]) continue;
        if (category && entry.category !== category) continue;
        if (matched.length >= limit) {
          hasMore = true;
          break;
        }
        matched.push(entry);
      }
      if (hasMore) break;
    }
    return { entries: matched, hasMore };
  }

  return {
    logsDir,

    info: (category, message, meta) => append("info", category, message, meta),
    warn: (category, message, meta) => append("warn", category, message, meta),
    error: (category, message, meta) => append("error", category, message, meta),

    readEntries,

    /** Resolves once every queued append has settled (kept for API symmetry). */
    close: async () => {
      await writeChain;
    },
  };
}

const LOG_FILE_PREFIX = (day) => `slatesync-${day}`;

function formatLine(date, level, category, message, meta) {
  const metaText = formatMeta(meta);
  const messageText = sanitizeMessage(message);
  const tail = metaText ? ` · ${metaText}` : "";
  return `[${formatTimestamp(date)}] [${level.toUpperCase()}] [${category}] ${messageText}${tail}\n`;
}

function sanitizeMessage(message) {
  return String(message ?? "")
    .replace(/\s*\r?\n\s*/g, " · ")
    .trim();
}

function formatMeta(meta) {
  if (!meta || typeof meta !== "object") return "";
  return Object.entries(meta)
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([key, value]) => `${key}=${formatMetaValue(value)}`)
    .join(" · ");
}

function formatMetaValue(value) {
  if (value instanceof Error) {
    return quoteMetaValue(value.message || String(value));
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return quoteMetaValue(String(value ?? ""));
}

function quoteMetaValue(text) {
  return /[\s·="]/.test(text) ? JSON.stringify(text) : text;
}

function formatTimestamp(date) {
  const time = [
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
  ].join(":");
  return `${dayKey(date)} ${time}.${pad(date.getMilliseconds(), 3)}`;
}

function dayKey(date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function shiftDays(date, days) {
  const shifted = new Date(date.getTime());
  shifted.setDate(shifted.getDate() + days);
  return shifted;
}

function pad(value, width = 2) {
  return String(value).padStart(width, "0");
}

function normalizeLimit(limit) {
  const value = Number(limit);
  if (!Number.isFinite(value)) return DEFAULT_READ_LIMIT;
  return Math.min(MAX_READ_LIMIT, Math.max(1, Math.trunc(value)));
}

function normalizeLevel(level) {
  return level === "info" || level === "warn" || level === "error" ? level : null;
}

/** Parse one log line back into a structured entry; malformed lines are skipped. */
export function parseLogLine(line) {
  const match = LINE_PATTERN.exec(String(line || "").trim());
  if (!match) return null;
  let message = match[4];
  const meta = {};
  // Pop recognized `key=value` pairs off the tail. Unknown segments stop the
  // scan, so messages that merely contain "·" survive parsing untouched.
  for (;;) {
    const separator = message.lastIndexOf(" · ");
    if (separator === -1) break;
    const tail = message.slice(separator + 3);
    const equals = tail.indexOf("=");
    if (equals === -1) break;
    const key = tail.slice(0, equals);
    if (!META_KEYS.has(key)) break;
    meta[key] = parseMetaValue(key, unquote(tail.slice(equals + 1)));
    message = message.slice(0, separator);
  }
  return {
    timestamp: match[1],
    level: match[2].toLowerCase(),
    category: match[3],
    message: message.trim(),
    phase: meta.phase ?? null,
    percent: meta.percent ?? null,
    completed: meta.completed ?? null,
    total: meta.total ?? null,
    pageNumber: meta.pageNumber ?? null,
  };
}

function parseMetaValue(key, value) {
  if (NUMBER_KEYS.has(key)) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : null;
  }
  if (key === "cacheHit") return value === "true";
  return value;
}

function unquote(value) {
  if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
    try {
      return JSON.parse(value);
    } catch {
      return value.slice(1, -1);
    }
  }
  return value;
}
