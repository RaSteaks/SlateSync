import assert from "node:assert/strict";
import {
  access,
  cp,
  mkdtemp,
  mkdir,
  readdir,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createProjectLibrary,
  DEFAULT_PROJECT_ID,
  DEFAULT_LIBRARY_FOLDER,
  LEGACY_DEFAULT_LIBRARY_FOLDER,
  defaultLibraryPath,
  migrateDefaultLibraryPath,
} from "../lib/project-library.mjs";
import {
  exportProjectPackage,
  exportProjectLibrary,
  libraryExportPath,
  projectExportPath,
  validateProjectPackage,
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

test("exports and imports a complete open project package without changing the source", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-project-transfer-"));
  const sourcePath = join(tempRoot, "source-library");
  const packagePath = projectExportPath(join(tempRoot, "Downloads"), "片名 / Day 01");
  const defaultPackagePath = projectExportPath(join(tempRoot, "Downloads"), "默认项目");
  const source = createProjectLibrary(sourcePath);
  const runtime = createProjectRuntime(source);
  let imported;

  try {
    const sourceProject = await source.createProject({
      name: "片名 / Day 01",
      description: "完整项目传输",
    });
    const sourceContext = await runtime.get(sourceProject.id);
    await sourceContext.taskStore.saveTask({
      id: "transfer-task",
      projectId: sourceProject.id,
      filename: "slate.png",
      status: "completed",
      result: { records: [{ scene: "A001" }] },
    });
    await sourceContext.diagnostics.saveSession({
      id: "transfer-diagnostic",
      projectId: sourceProject.id,
      filename: "slate.png",
      result: { records: [] },
    });
    await sourceContext.scenarioStore.importProfile({
      schemaVersion: 1,
      fingerprintVersion: 1,
      fingerprint: "transfer-profile",
      label: "传输版式",
      layout: {
        pages: [],
        headerTokens: ["场次"],
        cameraGroups: [],
        columnBands: [],
        rowBands: [],
        blockCount: 1,
      },
      fields: Object.fromEntries([
        "cardNumber", "videoCode", "scene", "shot", "take", "takeStatus",
        "description", "comments", "shotSize", "cameraPosition",
      ].map((field) => [field, {
        label: field,
        aliases: [],
        region: null,
        inherit: false,
        required: false,
      }])),
      recognition: { headerTokens: ["场次"], promptHints: [] },
      output: {
        resolve: {
          fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
          comments: { goodTake: "_OK", holdTake: "_KP" },
        },
      },
    });
    const sourceTaskBefore = await sourceContext.taskStore.loadTask("transfer-task");
    const sourceDiagnosticBefore = await sourceContext.diagnostics.loadSession("transfer-diagnostic");

    // 先归档再导出，覆盖开放运行时连接下的只读项目和归档状态保存。
    const archivedSource = await source.archiveProject(sourceProject.id);
    const exported = await source.exportProjectPackage(sourceProject.id, packagePath);
    assert.equal(exported.archivedAt, archivedSource.archivedAt);
    assert.deepEqual((await readdir(packagePath)).sort(), [
      "diagnostics",
      "project.json",
      "project.sqlite",
      "slatesync-project.json",
      "tasks",
    ]);

    const packageInfo = await validateProjectPackage(packagePath);
    assert.equal(packageInfo.project.id, sourceProject.id);
    assert.equal(packageInfo.project.name, sourceProject.name);
    assert.equal(packageInfo.taskCount, 1);
    assert.equal(packageInfo.diagnosticCount, 1);
    const packageManifest = JSON.parse(await readFile(join(packagePath, "slatesync-project.json"), "utf8"));
    assert.equal(packageManifest.formatVersion, 1);
    assert.equal(packageManifest.project.id, sourceProject.id);
    assert.equal(packageManifest.project.archivedAt, archivedSource.archivedAt);

    imported = await source.importProjectPackage(packagePath);
    assert.notEqual(imported.id, sourceProject.id);
    assert.equal(imported.name, sourceProject.name);
    assert.equal(imported.description, sourceProject.description);
    assert.equal(imported.archivedAt, archivedSource.archivedAt);
    assert.equal(imported.canArchive, true);

    const importedContext = await runtime.get(imported.id, { allowArchived: true });
    const importedManifest = JSON.parse(await readFile(join(imported.directoryPath, "project.json"), "utf8"));
    assert.equal(importedManifest.id, imported.id);
    assert.equal(importedManifest.libraryId, (await source.getLibraryInfo()).id);
    assert.equal(importedManifest.formatVersion, 1);
    const importedTask = await importedContext.taskStore.loadTask("transfer-task");
    const importedDiagnostic = await importedContext.diagnostics.loadSession("transfer-diagnostic");
    assert.equal(importedTask.projectId, imported.id);
    assert.equal(importedTask.libraryId, (await source.getLibraryInfo()).id);
    assert.equal(importedDiagnostic.projectId, imported.id);
    assert.equal(importedDiagnostic.libraryId, (await source.getLibraryInfo()).id);
    assert.equal((await importedContext.scenarioStore.listProfiles()).length, 1);
    assert.equal(
      JSON.parse(await readFile(join(imported.directoryPath, "tasks", "transfer-task.json"), "utf8")).projectId,
      imported.id,
    );
    assert.equal(
      JSON.parse(await readFile(join(imported.directoryPath, "diagnostics", "transfer-diagnostic.json"), "utf8")).libraryId,
      (await source.getLibraryInfo()).id,
    );

    // 第二次导入允许同名，并且必须产生另一条项目身份。
    const importedAgain = await source.importProjectPackage(packagePath);
    assert.notEqual(importedAgain.id, imported.id);
    assert.equal(importedAgain.name, imported.name);
    await source.exportProjectPackage(DEFAULT_PROJECT_ID, defaultPackagePath);

    assert.deepEqual(await sourceContext.taskStore.loadTask("transfer-task"), sourceTaskBefore);
    assert.deepEqual(await sourceContext.diagnostics.loadSession("transfer-diagnostic"), sourceDiagnosticBefore);
  } finally {
    await runtime.close();
    await source.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("rejects unsafe project packages and refuses nested or existing destinations", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-project-invalid-"));
  const source = createProjectLibrary(join(tempRoot, "source-library"));
  const sourceProject = await source.createProject({ name: "安全边界" });
  const packagePath = projectExportPath(tempRoot, sourceProject.name);

  try {
    await source.exportProjectPackage(sourceProject.id, packagePath);
    const mixedCasePath = projectExportPath(tempRoot, "FILM.SLATESYNC-PROJECT");
    await source.exportProjectPackage(sourceProject.id, mixedCasePath);
    await access(mixedCasePath);
    const futurePath = join(tempRoot, "Future.slatesync-project");
    await cp(packagePath, futurePath, { recursive: true });
    const futureManifestPath = join(futurePath, "slatesync-project.json");
    const futureManifest = JSON.parse(await readFile(futureManifestPath, "utf8"));
    futureManifest.formatVersion = 999;
    await writeFile(futureManifestPath, JSON.stringify(futureManifest));
    await assert.rejects(
      () => validateProjectPackage(futurePath),
      (error) => error.code === "INVALID_PROJECT_PACKAGE" && /更高版本/.test(error.message),
    );

    const linkedFile = join(packagePath, "tasks", "outside.json");
    await symlink(futureManifestPath, linkedFile);
    await assert.rejects(
      () => validateProjectPackage(packagePath),
      (error) => error.code === "INVALID_PROJECT_PACKAGE" && /符号链接/.test(error.message),
    );

    const existingTarget = join(tempRoot, "Existing.slatesync-project");
    await mkdir(existingTarget);
    await assert.rejects(
      () => exportProjectPackage(sourceProject.directoryPath, existingTarget),
      (error) => error.code === "PROJECT_DESTINATION_EXISTS",
    );
    await assert.rejects(
      () => exportProjectPackage(sourceProject.directoryPath, join(sourceProject.directoryPath, "nested.slatesync-project")),
      (error) => error.code === "INVALID_PROJECT_DESTINATION",
    );
    assert.equal(
      projectExportPath(tempRoot, "片名 / Day:01"),
      join(tempRoot, "片名 _ Day_01.slatesync-project"),
    );
    assert.equal(
      projectExportPath(tempRoot, "FILM.SLATESYNC-PROJECT "),
      join(tempRoot, "FILM.SLATESYNC-PROJECT"),
    );
    assert.equal(
      projectExportPath(tempRoot, "CON"),
      join(tempRoot, "_CON.slatesync-project"),
    );
    assert.equal(
      projectExportPath(tempRoot, "com1.txt"),
      join(tempRoot, "_com1.txt.slatesync-project"),
    );
  } finally {
    await source.close();
    await rm(tempRoot, { recursive: true, force: true });
  }
});

test("keeps malformed legacy snapshots opaque and omits interrupted .tmp artifacts", async () => {
  const tempRoot = await mkdtemp(join(tmpdir(), "slatesync-project-legacy-snapshots-"));
  const source = createProjectLibrary(join(tempRoot, "source-library"));
  let imported;

  try {
    const sourceProject = await source.createProject({ name: "旧快照兼容" });
    const malformed = "{ legacy snapshot is not valid JSON";
    await writeFile(
      join(sourceProject.directoryPath, "tasks", "legacy-broken.json"),
      malformed,
    );
    await writeFile(
      join(sourceProject.directoryPath, "tasks", "legacy-broken.json.tmp"),
      "unfinished atomic write",
    );
    await writeFile(
      join(sourceProject.directoryPath, "project.json.tmp"),
      "unfinished manifest write",
    );

    const packagePath = projectExportPath(tempRoot, sourceProject.name);
    await source.exportProjectPackage(sourceProject.id, packagePath);
    assert.equal(
      await readFile(join(packagePath, "tasks", "legacy-broken.json"), "utf8"),
      malformed,
    );
    await assert.rejects(() => access(join(packagePath, "tasks", "legacy-broken.json.tmp")));
    await assert.rejects(() => access(join(packagePath, "project.json.tmp")));

    // A package assembled by an older build may still contain a crash leftover;
    // validation accepts it, while import keeps it out of the new project.
    await writeFile(
      join(packagePath, "tasks", "legacy-broken.json.tmp"),
      "unfinished package write",
    );
    await writeFile(join(packagePath, "project.json.tmp"), "unfinished package manifest write");
    imported = await source.importProjectPackage(packagePath);
    assert.equal(
      await readFile(join(imported.directoryPath, "tasks", "legacy-broken.json"), "utf8"),
      malformed,
    );
    await assert.rejects(() => access(join(imported.directoryPath, "tasks", "legacy-broken.json.tmp")));
    await assert.rejects(() => access(join(imported.directoryPath, "project.json.tmp")));
  } finally {
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
