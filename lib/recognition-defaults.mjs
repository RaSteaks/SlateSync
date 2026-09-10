// 识别默认值（上次成功识别的 provider/model/prompt）的 O(1) 读取层。
//
// 历史实现在每次打开项目时按 `created_at DESC, rowid DESC` 全量扫描 tasks 表
// 并 JSON.parse 每个完整 blob（含图片组、CSV base64），是大项目的打开瓶颈。
// 现在把扫描结果持久化到 project_meta，由 task-store 在写任务行的同一事务内
// 增量维护；读取端未命中或值损坏时才回退原扫描并回写。
//
// 已知折衷（方案评审接受）：键存在期间不会反映绕过 task-store 的外部工具
// 直改 SQLite；批量绕过 task-store 的写入路径应调用 invalidateRecognitionDefaults。

const DEFAULTS_KEY = "last_recognition_defaults";

// 公开摘要形状：与旧扫描实现返回值逐字段一致，测试与 IPC 契约都依赖它。
function publicDefaults(stored) {
  if (!stored) return null;
  return {
    providerId: String(stored.providerId),
    modelId: String(stored.modelId),
    customPrompt: String(stored.customPrompt || ""),
  };
}

// 读取原始键值（含平局比较所需的 source 信息）；缺失或损坏返回 null。
function readStoredDefaults(db) {
  const row = db.prepare(
    "SELECT value FROM project_meta WHERE key = ?",
  ).get(DEFAULTS_KEY);
  if (!row) return null;
  try {
    const value = JSON.parse(row.value);
    if (typeof value?.providerId !== "string" || typeof value?.modelId !== "string") {
      return null;
    }
    return value;
  } catch {
    return null;
  }
}

function writeStoredDefaults(db, value) {
  db.prepare(`
    INSERT INTO project_meta (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  `).run(DEFAULTS_KEY, JSON.stringify(value));
}

// 原始全量扫描：镜像旧实现的排序（created_at DESC, rowid DESC）与过滤规则
// （必须有 result + provider + model）。返回值额外携带 source 信息供增量维护。
function scanLastRecognitionDefaults(db) {
  const rows = db.prepare(
    "SELECT rowid AS sourceRowid, data_json FROM tasks ORDER BY created_at DESC, rowid DESC",
  ).iterate();
  for (const row of rows) {
    try {
      const task = JSON.parse(row.data_json);
      if (!task?.result || !task.provider || !task.model) continue;
      return {
        providerId: String(task.provider),
        modelId: String(task.model),
        customPrompt: String(task.customPrompt || ""),
        sourceTaskId: String(task.id ?? ""),
        sourceCreatedAt: String(task.createdAt ?? ""),
        sourceRowid: Number(row.sourceRowid),
      };
    } catch {
      // Skip malformed legacy rows and continue to the next successful task.
    }
  }
  return null;
}

/**
 * 读取当前识别默认值：先查 project_meta 键，未命中或值损坏时回退全量扫描并回写。
 * @param {import("better-sqlite3").Database} db 已打开的项目库连接
 * @returns {{providerId: string, modelId: string, customPrompt: string} | null}
 */
export function readLastRecognitionDefaults(db) {
  let stored = readStoredDefaults(db);
  if (!stored) {
    stored = scanLastRecognitionDefaults(db);
    // 扫描命中才回写；空库不写键，保持"未命中"语义由下次扫描兜底。
    if (stored) writeStoredDefaults(db, stored);
  }
  return publicDefaults(stored);
}

/**
 * 任务保存时增量维护默认值键。必须在写任务行的同一事务内调用。
 * @param {import("better-sqlite3").Database} db 已打开的项目库连接
 * @param {object} task 即将写入的任务数据（含 id/provider/model/result/createdAt）
 * @param {number} rowid 被写任务行的真实 rowid（ON CONFLICT 更新已有行时
 *   lastInsertRowid 不指向被更新行，调用方需按主键回查）。
 */
export function recordRecognitionDefaults(db, task, rowid) {
  const qualifies = Boolean(task?.result && task.provider && task.model);
  const stored = readStoredDefaults(db);
  // 修订：源任务被编辑成不再携带成功结果时删除键，让下一次读取回退扫描
  // 选中下一个成功任务——否则过期键会把已不合格的任务当默认值返回。
  if (stored && !qualifies && String(task?.id ?? "") === String(stored.sourceTaskId ?? "")) {
    clearRecognitionDefaults(db, task.id);
    return;
  }
  if (!qualifies) return;
  const candidate = {
    providerId: String(task.provider),
    modelId: String(task.model),
    customPrompt: String(task.customPrompt || ""),
    sourceTaskId: String(task.id ?? ""),
    sourceCreatedAt: String(task.createdAt ?? ""),
    sourceRowid: Number(rowid),
  };
  const sourceCreatedAt = String(stored?.sourceCreatedAt ?? "");
  // 平局规则镜像扫描排序：created_at 更晚者胜；相同（编辑既有任务的常态）
  // 时 rowid 不小于源行才接管键，保证"编辑当前源任务更新、编辑更旧任务不更新"。
  const wins = !stored
    || candidate.sourceCreatedAt > sourceCreatedAt
    || (candidate.sourceCreatedAt === sourceCreatedAt
      && candidate.sourceRowid >= Number(stored?.sourceRowid ?? Number.NEGATIVE_INFINITY));
  if (!wins) return;
  writeStoredDefaults(db, candidate);
}

/**
 * 删除任务时调用：仅当被删任务正是键的源任务时删键，其余删除不影响键。
 * @param {import("better-sqlite3").Database} db 已打开的项目库连接
 * @param {string} taskId 被删除的任务 ID
 */
export function clearRecognitionDefaults(db, taskId) {
  const stored = readStoredDefaults(db);
  if (!stored) return;
  if (String(stored.sourceTaskId ?? "") === String(taskId ?? "")) {
    db.prepare("DELETE FROM project_meta WHERE key = ?").run(DEFAULTS_KEY);
  }
}

/**
 * 批量绕过 task-store 的任务写入（legacy 迁移、整包导入）后调用：无条件删键，
 * 强制下一次读取重新扫描并回写，避免旧键遮蔽新导入的更新任务。
 * @param {import("better-sqlite3").Database} db 已打开的项目库连接
 */
export function invalidateRecognitionDefaults(db) {
  db.prepare("DELETE FROM project_meta WHERE key = ?").run(DEFAULTS_KEY);
}
