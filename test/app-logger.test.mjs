import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { createAppLogger, parseLogLine } from "../lib/app-logger.mjs";

// The logger owns no global state, so every test builds a fresh instance in
// its own temp directory (mirroring the isolated userData rule).
async function createTempRoot() {
  return mkdtemp(join(tmpdir(), "slatesync-app-logger-"));
}

function fixedClock(startIso) {
  let current = new Date(startIso).getTime();
  return () => {
    current += 5;
    return new Date(current);
  };
}

test("writes human-readable daily log files with structured meta that parses back", async () => {
  const root = await createTempRoot();
  try {
    const logger = createAppLogger(root, { now: fixedClock("2026-08-26T10:00:00") });
    logger.info("app", "SlateSync 0.1.0 启动（darwin）");
    logger.info("recognition", "正在主识别第 3/8 页", {
      phase: "primary",
      percent: 45,
      completed: 3,
      total: 8,
      pageNumber: 3,
    });
    logger.warn("recognition", "本地 OCR 不可用");
    logger.error("app", "初始化失败", { error: new Error("boom happened") });
    await logger.close();

    const files = await readdir(join(root, "logs"));
    assert.deepEqual(files, ["slatesync-2026-08-26.log"]);
    const content = await readFile(join(root, "logs", "slatesync-2026-08-26.log"), "utf8");
    const lines = content.split("\n").filter(Boolean);
    assert.equal(lines.length, 4);
    assert.match(lines[0], /^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[INFO\] \[app\] SlateSync 0\.1\.0 启动（darwin）$/);
    assert.match(lines[1], /\[INFO\] \[recognition\] 正在主识别第 3\/8 页 · phase=primary · percent=45 · completed=3 · total=8 · pageNumber=3$/);
    assert.match(lines[2], /\[WARN\] \[recognition\] 本地 OCR 不可用$/);
    assert.match(lines[3], /\[ERROR\] \[app\] 初始化失败 · error="boom happened"$/);

    const progress = parseLogLine(lines[1]);
    assert.deepEqual(progress, {
      timestamp: progress.timestamp,
      level: "info",
      category: "recognition",
      message: "正在主识别第 3/8 页",
      phase: "primary",
      percent: 45,
      completed: 3,
      total: 8,
      pageNumber: 3,
    });
    // Read API returns the same entries newest-first. Error objects serialize
    // into the line; unknown meta keys such as `error` intentionally stay in
    // the message so the log viewer keeps failure details visible.
    const read = await logger.readEntries();
    assert.equal(read.entries.length, 4);
    assert.equal(read.hasMore, false);
    assert.equal(read.entries[0].message, '初始化失败 · error="boom happened"');
    assert.equal(read.entries[0].level, "error");
    assert.equal(read.entries[1].message, "本地 OCR 不可用");
    assert.equal(read.entries[2].percent, 45);
    assert.equal(read.entries[2].phase, "primary");
    assert.equal(read.entries[3].category, "app");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("log files are created with owner-only permissions", async () => {
  const root = await createTempRoot();
  try {
    const logger = createAppLogger(root, { now: fixedClock("2026-08-26T10:00:00") });
    logger.info("app", "权限检查");
    await logger.close();
    const info = await stat(join(root, "logs", "slatesync-2026-08-26.log"));
    assert.equal(info.mode & 0o777, 0o600);
    const dirInfo = await stat(join(root, "logs"));
    assert.equal(dirInfo.mode & 0o777, 0o700);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("rotates by calendar day and prunes files beyond the retention window", async () => {
  const root = await createTempRoot();
  try {
    // Simulate a session that starts on day 1 and crosses into day 9: the
    // day-9 write must rotate the file and prune the now-outdated day-1 file.
    let current = new Date("2026-08-01T09:00:00").getTime();
    const advanceDays = (days) => {
      current += days * 24 * 60 * 60 * 1000;
    };
    const logger = createAppLogger(root, { now: () => new Date(current), retentionDays: 7 });
    logger.info("app", "第一天");
    await logger.close();

    advanceDays(8);
    logger.info("app", "第九天");
    await logger.close();

    const files = (await readdir(join(root, "logs"))).sort();
    // Day 1 is 8 days before day 9 and falls outside the 7-day window.
    assert.deepEqual(files, ["slatesync-2026-08-09.log"]);
    const read = await logger.readEntries();
    assert.deepEqual(read.entries.map((entry) => entry.message), ["第九天"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("prunes pre-existing outdated files on the first write of a session", async () => {
  const root = await createTempRoot();
  try {
    const logsDir = join(root, "logs");
    await mkdir(logsDir, { recursive: true, mode: 0o700 });
    await writeFile(join(logsDir, "slatesync-2026-01-01.log"), "[2026-01-01 08:00:00.000] [INFO] [app] 旧日志\n");
    await writeFile(join(logsDir, "slatesync-2026-01-08.log"), "[2026-01-08 08:00:00.000] [INFO] [app] 边界日志\n");
    await writeFile(join(logsDir, "notes.txt"), "not a log file");

    const logger = createAppLogger(root, {
      now: fixedClock("2026-01-10T12:00:00"),
      retentionDays: 7,
    });
    logger.info("app", "新会话");
    await logger.close();

    const files = (await readdir(logsDir)).sort();
    // 2026-01-08 is within the 7-day window of 2026-01-10; 2026-01-01 is not,
    // and unrelated files are never touched by pruning.
    assert.deepEqual(files, ["notes.txt", "slatesync-2026-01-08.log", "slatesync-2026-01-10.log"]);
    const read = await logger.readEntries();
    assert.deepEqual(read.entries.map((entry) => entry.message), ["新会话", "边界日志"]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("readEntries filters by level and category and reports truncation", async () => {
  const root = await createTempRoot();
  try {
    const logger = createAppLogger(root, { now: fixedClock("2026-08-26T10:00:00") });
    logger.info("app", "启动");
    logger.info("recognition", "正在提取文字", { percent: 10 });
    logger.warn("recognition", "OCR 降级");
    logger.error("recognition", "识别失败");
    logger.info("app", "退出");
    await logger.close();

    const warnAndUp = await logger.readEntries({ level: "warn" });
    assert.deepEqual(warnAndUp.entries.map((entry) => entry.message), ["识别失败", "OCR 降级"]);

    const recognitionOnly = await logger.readEntries({ category: "recognition" });
    assert.deepEqual(recognitionOnly.entries.map((entry) => entry.message), ["识别失败", "OCR 降级", "正在提取文字"]);

    const limited = await logger.readEntries({ limit: 2 });
    assert.deepEqual(limited.entries.map((entry) => entry.message), ["退出", "识别失败"]);
    assert.equal(limited.hasMore, true);

    const exact = await logger.readEntries({ limit: 5 });
    assert.equal(exact.hasMore, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("serialized appends preserve order even when fired without awaiting", async () => {
  const root = await createTempRoot();
  try {
    const logger = createAppLogger(root, { now: fixedClock("2026-08-26T10:00:00") });
    for (let index = 0; index < 60; index++) {
      logger.info("app", `事件 ${index}`);
    }
    await logger.close();
    const read = await logger.readEntries({ limit: 2000 });
    // Newest-first result: the chronological order must still be a strict
    // 0..59 sequence reversed.
    assert.deepEqual(
      read.entries.map((entry) => entry.message),
      Array.from({ length: 60 }, (_, index) => `事件 ${59 - index}`),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a broken logs directory never throws from log or read calls", async () => {
  // Point the logger at a path occupied by a regular file: mkdir fails on
  // every append, which must be swallowed rather than reach callers.
  const root = await createTempRoot();
  try {
    const blocker = join(root, "blocker");
    await writeFile(blocker, "not a directory");
    const logger = createAppLogger(join(root, "blocker"), {
      now: fixedClock("2026-08-26T10:00:00"),
    });
    logger.info("app", "这条日志会失败");
    logger.error("app", "这条也会失败");
    await logger.close();
    const read = await logger.readEntries();
    assert.deepEqual(read, { entries: [], hasMore: false });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("multi-line messages collapse into a single log line", async () => {
  const root = await createTempRoot();
  try {
    const logger = createAppLogger(root, { now: fixedClock("2026-08-26T10:00:00") });
    logger.error("app", "第一行\n第二行");
    await logger.close();
    const read = await logger.readEntries();
    assert.equal(read.entries.length, 1);
    assert.equal(read.entries[0].message, "第一行 · 第二行");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("parseLogLine ignores malformed lines and preserves message separators", () => {
  assert.equal(parseLogLine(""), null);
  assert.equal(parseLogLine("random text without structure"), null);
  assert.equal(parseLogLine("[2026-08-26 10:00:00.000] [INFO] recognition 丢失分类括号"), null);

  // Message text containing "·" and "=" without a known meta key stays intact.
  const entry = parseLogLine(
    "[2026-08-26 10:00:00.000] [INFO] [recognition] 识别完成 · 12 条记录 · provider=openai",
  );
  assert.equal(entry.message, "识别完成 · 12 条记录");
  assert.equal(entry.percent, null);
  assert.equal(entry.phase, null);

  // Quoted meta values survive round trips.
  const quoted = parseLogLine(
    '[2026-08-26 10:00:00.000] [INFO] [app] 引用值 · phase="multi word phase"',
  );
  assert.equal(quoted.phase, "multi word phase");
});
