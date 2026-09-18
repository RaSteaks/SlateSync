// Isolated microbenchmark: synthetic, unencrypted projects only. No Electron,
// user library, credentials, or timing assertions; output is measurement evidence.
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createProjectLibrary } from "../../lib/project-library.mjs";
import { createProjectRuntime } from "../../lib/project-runtime.mjs";
import { invalidateRecognitionDefaults, readLastRecognitionDefaults } from "../../lib/recognition-defaults.mjs";

async function measure(fn, repeats = 7) {
  const samples = [];
  for (let i = 0; i < repeats; i++) {
    const start = performance.now();
    await fn();
    samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  return Number(samples[Math.floor(samples.length / 2)].toFixed(3));
}

const results = [];
for (const count of [1000, 5000]) {
  const root = await mkdtemp(join(tmpdir(), "slatesync-project-open-bench-"));
  const library = createProjectLibrary(join(root, "library"));
  const runtime = createProjectRuntime(library);
  try {
    const project = await library.createProject({ name: "Synthetic draft history" });
    const context = await runtime.get(project.id);
    const db = context.db;
    const timestamp = "2026-01-01T00:00:00.000Z";
    const insert = db.prepare("INSERT INTO tasks (id, data_json, summary_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?)");
    db.transaction(() => {
      for (let i = 0; i < count; i++) {
        const task = { id: `draft-${i}`, filename: `slate-${i}.png`, status: "draft", createdAt: timestamp, updatedAt: timestamp };
        insert.run(task.id, JSON.stringify({ ...task, imageDataGroups: [["x".repeat(8192)]] }),
          JSON.stringify({ ...task, recordCount: 0, pageCount: 1 }), timestamp, timestamp);
      }
      invalidateRecognitionDefaults(db);
    })();

    // Exact former no-result path: walk full task blobs on every read.
    const previousDefaultsRead = () => {
      for (const row of db.prepare("SELECT rowid AS sourceRowid, data_json FROM tasks ORDER BY created_at DESC, rowid DESC").iterate()) {
        const task = JSON.parse(row.data_json);
        if (task?.result && task.provider && task.model) throw new Error("fixture must contain drafts only");
      }
    };
    const firstDefaultsReadMs = await measure(() => assert.equal(readLastRecognitionDefaults(db), null), 1);
    const previousDefaultsMs = await measure(previousDefaultsRead);
    const cachedDefaultsMs = await measure(() => assert.equal(readLastRecognitionDefaults(db), null));
    const previousStats = "SELECT COUNT(*) AS count, MAX(updated_at) AS latest FROM tasks";
    const optimizedStats = "SELECT (SELECT COUNT(*) FROM tasks) AS count, (SELECT MAX(updated_at) FROM tasks) AS latest";
    assert.deepEqual(db.prepare(optimizedStats).get(), db.prepare(previousStats).get());
    const previousStatsMs = await measure(() => db.prepare(previousStats).get());
    const optimizedStatsMs = await measure(() => db.prepare(optimizedStats).get());
    const warmSnapshotMs = await measure(async () => {
      const current = await runtime.get(project.id);
      const tasks = await current.taskStore.listTasks();
      assert.equal(tasks.length, count);
      assert.equal(current.project.taskCount, count);
    });
    await runtime.closeProject(project.id);
    const reopenedSnapshotMs = await measure(async () => {
      const current = await runtime.get(project.id);
      assert.equal((await current.taskStore.listTasks()).length, count);
    }, 1);
    results.push({ count, payloadBytesPerTask: 8192, firstDefaultsReadMs, previousDefaultsMs,
      cachedDefaultsMs, previousStatsMs, optimizedStatsMs, warmSnapshotMs, reopenedSnapshotMs });
  } finally {
    await runtime.close(); await library.close(); await rm(root, { recursive: true, force: true });
  }
}
console.log(JSON.stringify({ note: "Medians of 7 samples except first/reopen (1); storage path only, no IPC/GUI or encryption.", results }, null, 2));
