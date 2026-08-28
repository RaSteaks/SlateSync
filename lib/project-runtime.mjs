// Lazily opened services for the currently addressable Project Library.
//
// Each runtime entry is bound to one project directory. IPC handlers still
// resolve the project on every request so a renderer cannot reuse a store from
// another project by changing only its local state.
import { createDiagnosticsStore } from "./diagnostics.mjs";
import { createScenarioStore } from "./scenario/store.mjs";
import { createTaskStore } from "./task-store.mjs";
import { SQLITE_FILENAMES } from "./sqlite-store.mjs";

export function createProjectRuntime(projectLibrary, options = {}) {
  const contexts = new Map();

  return {
    async get(projectId, { allowArchived = false } = {}) {
      const project = await projectLibrary.getProject(projectId, { allowArchived });
      let context = contexts.get(project.id);
      if (!context) {
        const storeOptions = {
          filename: SQLITE_FILENAMES.project,
        };
        context = {
          project,
          taskStore: createTaskStore(project.directoryPath, storeOptions),
          scenarioStore: createScenarioStore(project.directoryPath, {
            ...storeOptions,
            matching: options.matching,
          }),
          diagnostics: createDiagnosticsStore(project.directoryPath, storeOptions),
        };
        contexts.set(project.id, context);
      } else {
        // Refresh metadata/settings after a project settings or archive update.
        context.project = project;
      }
      return context;
    },

    async closeProject(projectId) {
      const context = contexts.get(projectId);
      if (!context) return;
      // Destructive project removal must close every SQLite owner before the
      // project directory can be removed on all supported platforms.
      contexts.delete(projectId);
      await Promise.all([
        context.taskStore.close(),
        context.scenarioStore.close(),
        context.diagnostics.close(),
      ]);
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
    },
  };
}
