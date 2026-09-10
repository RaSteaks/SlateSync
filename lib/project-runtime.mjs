// Lazily opened services for the currently addressable Project Library.
//
// Each runtime entry is bound to one project directory. IPC handlers still
// resolve the project on every request so a renderer cannot reuse a store from
// another project by changing only its local state.
//
// 每个项目只开一个共享 SQLite 句柄：task/scenario/diagnostics 三个 store 注入
// 复用同一连接，消除每请求临时开库、重复 DDL、mkdir/chmod 与多写者竞争。
// 每次请求仍从 library 索引行刷新项目元数据（设置、默认值、任务计数），
// 保持"每请求读最新"的语义，不需要失效协议。
import { createDiagnosticsStore } from "./diagnostics.mjs";
import { createScenarioStore } from "./scenario/store.mjs";
import { createTaskStore } from "./task-store.mjs";
import {
  closeSlateDatabase,
  openSlateDatabase,
  SQLITE_FILENAMES,
} from "./sqlite-store.mjs";

export function createProjectRuntime(projectLibrary, options = {}) {
  const contexts = new Map();

  return {
    async get(projectId, { allowArchived = false } = {}) {
      // getProjectRow 只做 library 主键查询与归档检查，成本低且保证
      // 归档/删除/改名在这些检查上即时生效；随后用共享句柄做廉价刷新。
      const row = await projectLibrary.getProjectRow(projectId, { allowArchived });
      let context = contexts.get(row.id);
      if (!context) {
        const { db } = openSlateDatabase(row.directoryPath, {
          kind: "project",
          filename: SQLITE_FILENAMES.project,
        });
        const storeOptions = {
          filename: SQLITE_FILENAMES.project,
          db,
        };
        context = {
          db,
          project: await projectLibrary.summarizeProjectRow(row, {
            db,
            includeSettings: true,
          }),
          taskStore: createTaskStore(row.directoryPath, storeOptions),
          scenarioStore: createScenarioStore(row.directoryPath, {
            ...storeOptions,
            matching: options.matching,
          }),
          diagnostics: createDiagnosticsStore(row.directoryPath, storeOptions),
        };
        contexts.set(row.id, context);
      } else {
        // Refresh metadata/settings after a project settings or archive update.
        context.project = await projectLibrary.summarizeProjectRow(row, {
          db: context.db,
          includeSettings: true,
        });
      }
      return context;
    },

    async closeProject(projectId) {
      const context = contexts.get(projectId);
      if (!context) return;
      // Destructive project removal must close every SQLite owner before the
      // project directory can be removed on all supported platforms.
      contexts.delete(projectId);
      // 三个 store 复用注入句柄，close() 只等待各自的 ready 完成；
      // 共享句柄在这里关闭唯一一次。
      await Promise.all([
        context.taskStore.close(),
        context.scenarioStore.close(),
        context.diagnostics.close(),
      ]);
      closeSlateDatabase(context.db);
    },

    async close() {
      const entries = [...contexts.values()];
      contexts.clear();
      await Promise.all(
        entries.flatMap((context) => [
          context.taskStore.close(),
          context.scenarioStore.close(),
          context.diagnostics.close(),
        ]),
      );
      for (const context of entries) closeSlateDatabase(context.db);
    },
  };
}
