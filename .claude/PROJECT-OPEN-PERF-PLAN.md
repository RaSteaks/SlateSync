# 优化「打开项目」耗时 + 前端↔数据库连接 — 实施方案

> 2026-09-06 · 状态：已完成（代码与自动化验证，2026-09-12 更新）
> 背景：启动 SlateSync 后，点开一个项目到工作台可用的时间过长。本方案优化打开项目主链路与前端↔数据库连接路径。

## 状态与交接

- 阶段 1–5 已实施：共享 SQLite 连接、识别默认值 O(1) 读取、JSON 迁移完成标记、
  `tasks.summary_json` 摘要列、单次 `load-project-snapshot` IPC 及相应契约登记均已落地。
- 自动化验证已通过：完整 Vitest、类型检查、JavaScript/Python 语法检查，以及隔离
  Electron 冒烟验证；实现事实和测试记录同步保存在根目录 `AGENT.md`。
- 阶段 6（项目列表 N+1、启动期并行化、语句缓存）是可选后续优化，本方案未实施；
  如无新的性能证据，不应将其视为当前阻塞项。

## Context（背景）

用户反馈：启动 SlateSync 后，**点开一个项目到工作台可用的时间过长**。要求优化打开项目主链路，并优化前端与数据库之间的连接。

经代码探索确认，每次打开项目（renderer 并行发 3 个 IPC：`load-project` / `list-scenarios` / `list-tasks`，`src/renderer/App.tsx:388-393`）在主进程实际发生：

| # | 瓶颈 | 位置 |
|---|------|------|
| 1 | 每个 IPC 都触发 `projectSummary()` **临时打开 project.sqlite → 全量 DDL exec → mkdir/chmod → COUNT/MAX → 读 settings → 关闭**（`load-project` 还绕过 runtime 直接调 `projectLibrary.getProject`） | `lib/project-runtime.mjs:15-37`、`lib/project-library.mjs:589-636`、`electron/ipc-handlers.mjs:336-341` |
| 2 | `migrateJsonDirectory` **每次**创建 store 时 readdir + 解析 `tasks/`、`diagnostics/` 下全部 JSON 快照（`saveTask` 每次双写快照，目录永远有文件），无完成标记 —— **很可能是最大单项开销** | `lib/sqlite-store.mjs:131-181`、`lib/task-store.mjs:22-44`、`lib/diagnostics.mjs:23-38` |
| 3 | `readLastRecognitionDefaults` 按创建时间倒序**遍历并 JSON.parse 所有任务完整 blob**（含图片组、CSV base64） | `lib/project-library.mjs:745-765` |
| 4 | `listTasks` 为拼 ~10 个摘要字段**解析所有任务完整 blob**（表只有 `id, data_json, created_at, updated_at`） | `lib/task-store.mjs:100-127` |
| 5 | 同一 project.sqlite 被 **4 个连接**打开（task/scenario/diagnostics 三个常驻 + 临时），各执行一遍 DDL | `lib/task-store.mjs:18` 等 |

次要：打开项目 3 个 IPC 各自重复走守卫与解析；App 启动已取 `get-library-info`，项目页挂载又取一次（`ProjectLibraryPage.tsx:38-55`）。

## 方案总览

核心思路：**每项目一个共享常驻连接** + **消除重复解析**（快照迁移标记、defaults 持久化到 `project_meta`、摘要列），最后合并 IPC 为一次快照读取。不改渲染端缓存来掩盖问题；保持每请求读最新数据的语义（不做失效协议）。

预期收益（点击打开 → 工作台可用）：

| 阶段 | 消除的开销 | 占比估计 |
|---|---|---|
| 阶段 2 迁移标记 + defaults 键 | 每次打开全量快照重读/解析；O(N) blob 扫描 | ~40-70%（快照多的项目） |
| 阶段 1 共享连接 | 3 次临时开库 + 3 次 DDL + mkdir/chmod + 冗余 COUNT/settings | ~15-25% |
| 阶段 3 摘要列 | `list-tasks` 的 N 次全量 blob 解析 | ~10-20%，随任务数增长 |
| 阶段 4 合并 IPC + 去重复取 | 3→1 次往返；重复 `get-library-info` | ~5-10% |

落地顺序：1 → 2 → 3 → 4+5（同 commit）。阶段 6（项目列表 N+1、启动期并行化）**本次不做**，仅实测后需要再做。

## 实施步骤

### 阶段 1 — 每项目单一共享连接 + 消除每请求重开库

1.1 `lib/sqlite-store.mjs` `openSlateDatabase`（L23）：现有 pragma 后加 `db.pragma("synchronous = NORMAL")`；`kind === "project"` 时调用 `ensureProjectColumns(db)`——`PRAGMA table_info(tasks)` 无 `summary_json` 则 `ALTER TABLE tasks ADD COLUMN summary_json TEXT`（**必须 nullable**，保证新库与迁移库 `table_info` 完全一致）；同时在 `PROJECT_SCHEMA` 的 `CREATE TABLE tasks` 里加 `summary_json TEXT` 收敛。

1.2 三个 store 工厂（`lib/task-store.mjs:16`、`lib/scenario/store.mjs:16`、`lib/diagnostics.mjs:18`）支持注入句柄：`options.db` 存在则复用，否则照旧自开（向后兼容，现有测试全部无参调用不受影响）；`close()` 只在自开（`owned`）时才关句柄。

1.3 `lib/project-library.mjs` 拆分 `getProject`：
- `getProjectRow(id, {allowArchived})` — 仅 `findProjectRow` + 归档检查 + `checkedProjectDirectory` + `canArchive`，**不碰 project.sqlite**
- `summarizeProjectRow(row, { db = null, includeSettings })` — 现 `projectSummary` 主体；注入 db 则复用，否则临时打开（`listProjects` 保持不变）
- `getProject` = 两者组合，公开行为不变

1.4 `lib/project-runtime.mjs` `get()`：每次先 `getProjectRow`（library 主键查，便宜）拿最新行；首次创建 context 时 `openSlateDatabase` 开**一个**共享句柄，传给三个 store，并 `summarizeProjectRow(row, {db, includeSettings:true})`；后续每次 get 用共享句柄做廉价 refresh（settings + defaults + COUNT/MAX，~0.1ms）——**保持每请求最新语义，无需失效协议**（不采用"context.project 缓存 + 手动刷新"方案，会破坏归档/删除检测与 taskCount 时效）。`closeProject`/`close`：关三个 store（仅 await 其 ready），再关共享句柄一次；`delete-project` 路径随之简化。

1.5 `electron/ipc-handlers.mjs` `load-project`（L336-341）改走 runtime：
```js
withProjectRead(id, async () => {
  const context = await resolveProjectContext(id, { readOnly: true });
  return sanitizeProject(context.project);
});
```
等价性已核实：现 `load-project` 用 `getProject(id)`（默认 allowArchived=true）＝ `readOnly: true` → `allowArchived: true`（`ipc-handlers.mjs:1129-1134`）；项目目录缺失时 `openSlateDatabase` 重建空库与今天 `list-scenarios`/`list-tasks` 路径行为一致。

### 阶段 2 — defaults O(1) 化 + 快照迁移标记

2.1 新建 `lib/recognition-defaults.mjs`（纯函数，接收 db 句柄）：
- `readLastRecognitionDefaults(db)` — 读 `project_meta` 键 `last_recognition_defaults`；未命中则跑原扫描（`ORDER BY created_at DESC, rowid DESC` 逐行 parse）并回写
- `recordRecognitionDefaults(db, task)` — 有 result+provider+model 才写；比较条件 `createdAt > sourceCreatedAt || (相等 && rowid >= sourceRowid)`（**必须存 `sourceTaskId`/`sourceCreatedAt`/`sourceRowid`**，平局规则镜像原 SQL 排序，否则过不了固定测试）；值损坏时回退扫描
- `clearRecognitionDefaults(db, taskId)` — 仅当 `sourceTaskId === taskId` 时删键
- `lib/project-library.mjs` 删除本地 `readLastRecognitionDefaults`（L745-765）改为 import

2.2 `lib/task-store.mjs`：`saveTask` 的 upsert 包进 `db.transaction(...)`，事务内最后 `recordRecognitionDefaults`（用 `lastInsertRowid`）；`deleteTask` 的 DELETE 同事务加 `clearRecognitionDefaults`；`updateTask` 走 saveTask 无需改。独立（自开）store 自动获得该能力（每个 `kind:"project"` 库都有 `project_meta`）。

2.3 **迁移完成标记**：`lib/sqlite-store.mjs` 加 `readAppMetaMarker`/`writeAppMetaMarker`（操作 `app_meta`，键 `json_migration_tasks_v1` / `json_migration_diagnostics_v1`）；两个 store 工厂的 `ready` 改为：有标记直接返回 0，否则跑 `migrateJsonDirectory` 后写标记。安全性：双写保持快照同步、`INSERT OR IGNORE` 幂等；唯一损失是首次迁移后外部手动放入的快照不再自动导入（头注释说明）。

### 阶段 3 — 任务摘要列，list-tasks 不再解析全量 blob

`lib/task-store.mjs`：
- `taskSummaryOf(data)`：现 `listTasks` 的投影 + `v: 1`（id/filename/provider/model/pageCount/scenarioId/recordCount/status/createdAt/updatedAt）
- `saveTask` upsert 加 `summary_json`（`summary_json = excluded.summary_json`）
- `listTasks` 改 `SELECT id, summary_json, data_json FROM tasks ORDER BY updated_at DESC`：有 summary 解析小 JSON；NULL 行解析 `data_json` 建摘要并收集，循环后**单事务回填**。畸形行保持跳过。`migrateLegacyData` 的 `copyRows`（`project-library.mjs:434`）与 `migrateJsonDirectory` 产生的 NULL 行由首次 `listTasks` 回填

### 阶段 4 — 合并 IPC + renderer 打开路径

4.1 `src/shared/contracts/index.ts`：`ProjectLoadSnapshot { project, scenarios, tasks }`；`SlateSyncApi.projects.loadSnapshot(request)`
4.2 `src/preload/index.ts`：`loadSnapshot` → `"load-project-snapshot"`
4.3 `electron/ipc-handlers.mjs`：新 handler——单个 `withProjectRead` → `resolveProjectContext(readOnly:true)` 一次 → `Promise.all([listProfiles(), listTasks()])` → `{project: sanitizeProject(...), scenarios, tasks}`。**保留**旧三通道（legacy `public/app.js`、`ProjectSettingsPage.tsx:61`、`WorkspacePage.tsx:446` 在用）
4.4 `src/renderer/App.tsx` `openProject`（L379-412）：改单次 `loadSnapshot`，守卫/flushSync 语义不变；带运行时能力检测 `typeof api.projects.loadSnapshot === "function"` 兜底回退三调用路径。`WorkspacePage` 靠 `useTaskStore.loadedProjectId` 跳过重取，无需改
4.5 `ProjectLibraryPage.tsx`：仅当 store 里 `library` 为 null 时才 `getLibraryInfo`（App 启动 `App.tsx:191-197` 已 seed）；projects 已在 store 时可跳过 loading 闪烁（stale-while-revalidate）
4.6 `useProviderModels` 的网络模型发现**保持现状**（主进程已有 5 分钟缓存 + 静态兜底，延后会话首次交互才有感）

### 阶段 5 — 契约登记（必须与阶段 4 同 commit）

- `.codex/refactor/additive/contracts/ipc.json` 加 `loadProjectSnapshot` 条目
- `test/baseline-contracts.test.mjs`（方法名 L84-105、通道 L108-129 列表）加 `load-project-snapshot`
- `test/refactor/ip-02/contract.test.ts`：fixture responses 加通道断言，更新操作数标题
- `.codex/refactor/baseline/persistence/schema.json` 登记 `tasks.summary_json`（`["summary_json","TEXT",0,null,0]`）——这是"reviewed drift"路径
- `AGENT.md` 追加条目（仓库惯例）
- **不得**升 `PROJECT_FORMAT_VERSION`（被测试与 `project-library-transfer.mjs:474-479` 兼容上限断言）

### 阶段 6（可选，本次不做）

仅当实测后仍需要：项目列表 N+1（把 `task_count`/`latest_task_at` 反范式进 library `projects` 表，在 `touchProjectActivity` 处维护）；`initialize()` 独立文件读取并行化（`electron/main.mjs:111,113,124,129`）；task-store 语句缓存。

## 测试

更新：`test/electron-ipc.test.mjs`（expectedChannels 加新通道 + handler 返回结构/sanitize 断言）、契约测试 `test/baseline-contracts.test.mjs`、`test/refactor/ip-02/contract.test.ts`、两个 fixture。`test/project-library.test.mjs:311-371`（defaults 继承语义：编辑当前源任务更新、编辑更旧任务不更新、**删除源任务回退到下一个成功任务**）是阶段 2 的验收门，必须原样通过。

新增：
- `test/project-runtime.test.mjs`：两次 get 同一 db/taskStore；closeProject 关一次共享句柄且可重建；注入句柄的 store 不关共享库；归档后 `get` 拒绝而 `readOnly` 通过；defaults 端到端流转
- `test/recognition-defaults.test.mjs`：首次读回填；无 result 不写；同 created_at 的 rowid 平局；删源任务后重扫选中更旧但被编辑过的任务；meta 值损坏回退扫描
- 扩展 `test/persistence.test.mjs`：summary_json 回填（第二条连接清列后 listTasks 重建）；迁移标记（重新放 `.json` 后再打开不导入）

## 风险与兼容性

- **单连接 vs WAL**：更安全——消除 project.sqlite 上的 3 写者竞争；剩余跨句柄写者（`updateProject`/`setArchived`/`createProject`/`migrateLegacyData` 的临时连接）短暂且受 `busy_timeout=5000` 保护；transfer 层用 SQLite online backup，不受打开句柄影响
- **存量库 ALTER**：`table_info` 守卫幂等、列 nullable、只前进不重写数据
- **外部工具直改 SQLite**：defaults 键存在期间不反映（接受，文档注明）
- **legacy renderer**：旧通道不动，`load-project` 走 runtime 后 payload 相同

## 验证

1. `npx vitest run`（全部现有 + 新增测试）；重点 `test/project-library.test.mjs`、`test/persistence*.test.mjs`、`test/electron-ipc.test.mjs`、契约测试
2. 性能对比：参照 `test-support/refactor/gateway-performance.mjs`，用 `test-support/synthetic-production-day.mjs` 生成含大量任务/快照的合成项目，分阶段计时「打开项目」链路（阶段 1→2→3→4 各测一次）
3. 手工端到端：`npm run dev` 启动 → 打开一个任务多、快照大的真实项目 → 工作台可用；再验证：改项目设置后重新打开设置生效、识别成功后新建任务继承 provider/model/prompt、删除该任务后 defaults 回退、归档/恢复/删除项目正常、legacy renderer（`--slatesync-renderer=legacy`）打开项目正常
