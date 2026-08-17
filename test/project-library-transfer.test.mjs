import assert from "node:assert/strict";
import { access, mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createProjectLibrary,
  DEFAULT_LIBRARY_FOLDER,
  defaultLibraryPath,
} from "../lib/project-library.mjs";
import {
  exportProjectLibrary,
  validateProjectLibrary,
} from "../lib/project-library-transfer.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";

test("default Project Library lives directly under Application Support", () => {
  const applicationSupport = "/Users/test/Library/Application Support";
  assert.equal(
    defaultLibraryPath(applicationSupport),
    join(applicationSupport, DEFAULT_LIBRARY_FOLDER),
  );
});

test("exports an open Project Library as an independent portable package", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-library-export-"));
  const sourcePath = join(tempRoot, DEFAULT_LIBRARY_FOLDER);
  const targetPath = join(
    tempRoot,
    "exports",
    "Local SlateSync Library.slatesync-library",
  );
  const source = createProjectLibrary(sourcePath);
  const sourceRuntime = createProjectRuntime(source);
  let exported;
  let exportedRuntime;

  try {
    const project = await source.createProject({ name: "可移植项目" });
    const sourceContext = await sourceRuntime.get(project.id);
    await sourceContext.taskStore.saveTask({
      id: "portable-task",
      filename: "slate.png",
      status: "completed",
      result: { records: [{ scene: "A001" }] },
    });

    // Keep source connections open to exercise SQLite online backup rather
    // than relying on closed files that happen not to have WAL state.
    const result = await exportProjectLibrary(sourcePath, targetPath);
    assert.equal(result.name, "Local SlateSync Library");
    assert.equal(result.projectCount, 2);
    await access(join(targetPath, "library.sqlite"));
    await access(join(targetPath, "Projects", project.id, "project.sqlite"));

    exported = createProjectLibrary(targetPath);
    exportedRuntime = createProjectRuntime(exported);
    const exportedContext = await exportedRuntime.get(project.id);
    assert.equal(
      (await exportedContext.taskStore.loadTask("portable-task")).filename,
      "slate.png",
    );
    assert.equal(
      (await sourceContext.taskStore.loadTask("portable-task")).filename,
      "slate.png",
    );
  } finally {
    await exportedRuntime?.close();
    await exported?.close();
    await sourceRuntime.close();
    await source.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("rejects malformed imports and existing export destinations", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-library-invalid-"));
  const malformed = join(tempRoot, "Broken.slatesync-library");
  const sourcePath = join(tempRoot, DEFAULT_LIBRARY_FOLDER);
  const source = createProjectLibrary(sourcePath);

  try {
    await mkdir(malformed, { recursive: true });
    await writeFile(join(malformed, "library.json"), "{}");
    await assert.rejects(
      () => validateProjectLibrary(malformed),
      (error) => error.code === "INVALID_PROJECT_LIBRARY",
    );

    // Force initialization before testing destination replacement protection.
    await source.getLibraryInfo();
    const existingTarget = join(tempRoot, "Existing.slatesync-library");
    await mkdir(existingTarget);
    await assert.rejects(
      () => exportProjectLibrary(sourcePath, existingTarget),
      (error) => error.code === "LIBRARY_DESTINATION_EXISTS",
    );
  } finally {
    await source.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});
