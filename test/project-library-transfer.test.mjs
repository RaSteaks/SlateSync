import assert from "node:assert/strict";
import { access, mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createProjectLibrary,
  DEFAULT_LIBRARY_FOLDER,
  LEGACY_DEFAULT_LIBRARY_FOLDER,
  defaultLibraryPath,
  migrateDefaultLibraryPath,
} from "../lib/project-library.mjs";
import {
  exportProjectLibrary,
  libraryExportPath,
  validateProjectLibrary,
} from "../lib/project-library-transfer.mjs";
import { createProjectRuntime } from "../lib/project-runtime.mjs";

test("default Project Library lives directly under Application Support", () => {
  const applicationSupport = "/Users/test/Library/Application Support";
  assert.equal(DEFAULT_LIBRARY_FOLDER, "Local SlateSync Library");
  assert.equal(
    defaultLibraryPath(applicationSupport),
    join(applicationSupport, DEFAULT_LIBRARY_FOLDER),
  );
  assert.equal(
    libraryExportPath(applicationSupport),
    join(applicationSupport, "Local SlateSync Library.slatesync-library"),
  );
});

test("renames the previous deployed default without changing its contents", async () => {
  const applicationSupport = await mkdtemp(join(tmpdir(), "slatesync-default-library-"));
  const legacyPath = join(applicationSupport, LEGACY_DEFAULT_LIBRARY_FOLDER);
  const marker = join(legacyPath, "existing-data.txt");
  try {
    await mkdir(legacyPath, { recursive: true });
    await writeFile(marker, "preserved");

    const migrated = await migrateDefaultLibraryPath(applicationSupport, [legacyPath]);

    assert.equal(migrated, join(applicationSupport, "Local SlateSync Library"));
    await access(join(migrated, "existing-data.txt"));
    await assert.rejects(() => access(legacyPath));
  } finally {
    await rm(applicationSupport, { recursive: true, force: true });
  }
});

test("preserves an explicitly configured legacy library when the short path is occupied", async () => {
  const applicationSupport = await mkdtemp(join(tmpdir(), "slatesync-default-collision-"));
  const legacyPath = join(applicationSupport, LEGACY_DEFAULT_LIBRARY_FOLDER);
  const preferredPath = join(applicationSupport, DEFAULT_LIBRARY_FOLDER);
  try {
    await mkdir(legacyPath, { recursive: true });
    await mkdir(preferredPath, { recursive: true });
    await writeFile(join(legacyPath, "active-data.txt"), "configured");
    await writeFile(join(preferredPath, "other-data.txt"), "occupied");

    const selected = await migrateDefaultLibraryPath(
      applicationSupport,
      [legacyPath],
      { preserveLegacyOnConflict: true },
    );

    assert.equal(selected, legacyPath);
    await access(join(legacyPath, "active-data.txt"));
    await access(join(preferredPath, "other-data.txt"));
  } finally {
    await rm(applicationSupport, { recursive: true, force: true });
  }
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
