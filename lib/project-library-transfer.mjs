// Portable Project Library validation and copy helpers.
//
// Library exports copy ordinary files normally but use SQLite's online backup
// API for every database. This avoids shipping WAL-dependent or partially
// copied database files while Electron still has read connections open.
import Database from "better-sqlite3";
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

import {
  DEFAULT_LIBRARY_FOLDER,
  LIBRARY_EXTENSION,
  LIBRARY_FORMAT_VERSION,
  PROJECT_FORMAT_VERSION,
  PROJECT_PACKAGE_EXTENSION,
  PROJECT_PACKAGE_FORMAT_VERSION,
  PROJECT_PACKAGE_MANIFEST,
} from "./project-library.mjs";
import { SQLITE_FILENAMES } from "./sqlite-store.mjs";

export async function validateProjectPackage(
  packagePath,
  { requireExtension = true } = {},
) {
  // 先验证固定目录边界，再打开 SQLite，确保外部包不会把路径或链接带入应用。
  const rootPath = resolve(String(packagePath || ""));
  await assertProjectPackageRoot(rootPath, { requireExtension });
  const packageManifest = await readProjectPackageManifest(rootPath);
  const projectManifest = await readJsonFile(
    join(rootPath, "project.json"),
    "无法读取项目包中的 project.json",
  );
  const packageProject = normalizePackageProject(packageManifest.project);
  const storageManifest = validateStorageManifest(projectManifest, packageProject);
  await validateProjectSnapshots(rootPath, packageProject);

  const dbPath = join(rootPath, SQLITE_FILENAMES.project);
  let db;
  try {
    db = new Database(dbPath, { readonly: true, fileMustExist: true });
    // 包清单的 updatedAt 记录库级活动时间，数据库继续校验项目自身的设置时间。
    const databaseInfo = inspectProjectDatabase(db, {
      ...packageProject,
      createdAt: storageManifest.createdAt,
      updatedAt: storageManifest.updatedAt,
    });
    return {
      type: packageManifest.type,
      path: rootPath,
      formatVersion: Number(packageManifest.formatVersion),
      project: packageProject,
      taskCount: databaseInfo.taskCount,
      diagnosticCount: databaseInfo.diagnosticCount,
    };
  } catch (error) {
    if (error?.code === "INVALID_PROJECT_PACKAGE") throw error;
    throw invalidProjectPackage(`无法读取项目包数据库：${error.message || error}`);
  } finally {
    db?.close();
  }
}

export async function exportProjectPackage(
  sourcePath,
  targetPath,
  project = null,
) {
  // 导出只复制项目边界内的数据；临时目录完成校验后才原子改名为目标目录。
  const source = resolve(String(sourcePath || ""));
  const target = resolve(String(targetPath || ""));
  const sourceInfo = await readProjectStorage(source, project);
  if (!hasExtensionIgnoreCase(basename(target), PROJECT_PACKAGE_EXTENSION)) {
    throw invalidProjectPackage("导出路径必须以 .slatesync-project 结尾");
  }
  assertSeparatePaths(
    source,
    target,
    "导出位置不能是当前项目或其内部目录",
    "INVALID_PROJECT_DESTINATION",
  );
  if (await pathExists(target)) {
    const error = new Error("目标位置已存在同名项目，请选择其他名称或位置");
    error.code = "PROJECT_DESTINATION_EXISTS";
    throw error;
  }

  await mkdir(dirname(target), { recursive: true });
  const staging = join(
    dirname(target),
    `.partial-${randomUUID()}-${basename(target)}`,
  );
  try {
    await copyPortableTree(source, staging, {
      skipNames: new Set([PROJECT_PACKAGE_MANIFEST]),
      errorFactory: invalidProjectPackage,
    });
    await backupSqliteTree(source, staging);
    await writeJsonAtomic(
      join(staging, PROJECT_PACKAGE_MANIFEST),
      {
        type: "slatesync-project",
        formatVersion: PROJECT_PACKAGE_FORMAT_VERSION,
        project: sourceInfo.project,
      },
    );
    // Validate the complete package before the atomic commit. Re-validating
    // the same directory after rename adds I/O and could otherwise trigger a
    // cleanup of the user's newly selected destination on a transient error.
    const packageInfo = await validateProjectPackage(staging);
    await rename(staging, target);
    return { ...packageInfo, path: target };
  } catch (error) {
    // 暂存目录由本次操作独占；失败或校验取消时不能触碰用户选择的目标目录。
    await rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

export async function importProjectPackageData(
  packagePath,
  targetPath,
  { projectId, libraryId, packageInfo: suppliedPackageInfo = null } = {},
) {
  // 导入始终在暂存副本中重绑定新归属，源项目和用户已存在目标均保持不变。
  // The Library composition root already validated this package before
  // allocating an ID; direct callers still get the standalone validation.
  const packageInfo = suppliedPackageInfo || await validateProjectPackage(packagePath);
  const nextProjectId = validateProjectId(projectId);
  const nextLibraryId = validateLibraryId(libraryId);
  const source = packageInfo.path;
  const target = resolve(String(targetPath || ""));
  if (await pathExists(target)) {
    const error = new Error("导入目标项目目录已存在，请重试");
    error.code = "PROJECT_DESTINATION_EXISTS";
    throw error;
  }
  assertSeparatePaths(
    source,
    target,
    "导入位置不能是项目包本身或其内部目录",
    "INVALID_PROJECT_DESTINATION",
  );

  await mkdir(dirname(target), { recursive: true });
  const staging = join(
    dirname(target),
    `.partial-${randomUUID()}-${basename(target)}`,
  );
  try {
    await copyPortableTree(source, staging, {
      skipNames: new Set([PROJECT_PACKAGE_MANIFEST]),
      errorFactory: invalidProjectPackage,
    });
    await backupSqliteTree(source, staging);
    await rebindImportedProject(staging, packageInfo.project, {
      projectId: nextProjectId,
      libraryId: nextLibraryId,
    });
    await validateProjectStorageDirectory(staging, {
      ...packageInfo.project,
      id: nextProjectId,
      libraryId: nextLibraryId,
    });
    await rename(staging, target);
    return {
      path: target,
      project: {
        ...packageInfo.project,
        id: nextProjectId,
        libraryId: nextLibraryId,
      },
    };
  } catch (error) {
    // 半重绑定项目不能暴露给 Library 索引；导入失败后清理所有暂存目录。
    await rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

export function projectExportPath(parentPath, projectName = "SlateSync Project") {
  const safeName = safeProjectExportName(projectName);
  const normalized = hasExtensionIgnoreCase(safeName, PROJECT_PACKAGE_EXTENSION)
    ? safeName
    : `${safeName}${PROJECT_PACKAGE_EXTENSION}`;
  return join(resolve(String(parentPath || "")), normalized);
}

export async function validateProjectLibrary(
  libraryPath,
  { requireExtension = true } = {},
) {
  const rootPath = resolve(String(libraryPath || ""));
  const rootStat = await lstat(rootPath).catch(() => null);
  if (!rootStat?.isDirectory() || rootStat.isSymbolicLink()) {
    throw invalidLibrary("请选择有效的 .slatesync-library 项目库目录");
  }
  if (requireExtension && !basename(rootPath).endsWith(LIBRARY_EXTENSION)) {
    throw invalidLibrary("项目库目录必须以 .slatesync-library 结尾");
  }

  // Imported libraries are opened in place. Reject links so a crafted package
  // cannot redirect project database access outside the directory selected by
  // the user.
  await assertTreeContainsNoLinks(rootPath);
  const manifest = await readManifest(rootPath);
  const formatVersion = Number(manifest.formatVersion);
  if (!Number.isInteger(formatVersion) || formatVersion < 1) {
    throw invalidLibrary("项目库格式版本无效");
  }
  if (formatVersion > LIBRARY_FORMAT_VERSION) {
    throw invalidLibrary("项目库由更高版本的 SlateSync 创建，请先升级应用");
  }

  const dbPath = join(rootPath, SQLITE_FILENAMES.library);
  let db;
  try {
    db = new Database(dbPath, { readonly: true, fileMustExist: true });
    const rows = db.prepare(
      "SELECT id, relative_path FROM projects",
    ).all();
    for (const row of rows) {
      const projectPath = checkedProjectPath(rootPath, row.relative_path);
      const projectDb = await lstat(
        join(projectPath, SQLITE_FILENAMES.project),
      ).catch(() => null);
      if (!projectDb?.isFile()) {
        throw invalidLibrary(`项目 ${row.id} 缺少 project.sqlite`);
      }
    }
    return {
      id: String(manifest.id || ""),
      name: String(manifest.name || "Local SlateSync Library"),
      path: rootPath,
      formatVersion,
      projectCount: rows.length,
    };
  } catch (error) {
    if (error?.code === "INVALID_PROJECT_LIBRARY") throw error;
    throw invalidLibrary(`无法读取项目库索引：${error.message || error}`);
  } finally {
    db?.close();
  }
}

export async function exportProjectLibrary(sourcePath, targetPath) {
  const source = resolve(String(sourcePath || ""));
  const target = resolve(String(targetPath || ""));
  // 兼容旧版任意 libraryPath；新生成或导入的项目库仍使用稳定扩展名。
  await validateProjectLibrary(source, { requireExtension: false });
  if (!basename(target).endsWith(LIBRARY_EXTENSION)) {
    throw invalidLibrary("导出路径必须以 .slatesync-library 结尾");
  }
  assertSeparatePaths(source, target);
  if (await pathExists(target)) {
    const error = new Error("目标位置已存在同名项目库，请选择其他名称或位置");
    error.code = "LIBRARY_DESTINATION_EXISTS";
    throw error;
  }

  await mkdir(dirname(target), { recursive: true });
  const staging = join(
    dirname(target),
    `.partial-${randomUUID()}-${basename(target)}`,
  );
  try {
    await copyPortableTree(source, staging);
    await backupSqliteTree(source, staging);
    // The staged copy is the final artifact; use this validation result rather
    // than reading the same library a second time after it has been committed.
    const libraryInfo = await validateProjectLibrary(staging);
    await rename(staging, target);
    return { ...libraryInfo, path: target };
  } catch (error) {
    // The staging directory is created by this operation and is never a user
    // selected library, so failed exports can be cleaned up without touching
    // either the source or an existing destination.
    await rm(staging, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

export function libraryExportPath(parentPath, folderName = DEFAULT_LIBRARY_FOLDER) {
  const safeFolder = basename(String(folderName || DEFAULT_LIBRARY_FOLDER));
  const normalized = safeFolder.endsWith(LIBRARY_EXTENSION)
    ? safeFolder
    : `${safeFolder}${LIBRARY_EXTENSION}`;
  return join(resolve(String(parentPath || "")), normalized);
}

async function copyPortableTree(
  source,
  target,
  { skipNames = new Set(), errorFactory = invalidLibrary } = {},
) {
  const stat = await lstat(source);
  if (stat.isSymbolicLink()) {
    // 同一套复制器服务两种包，错误文案必须指向当前操作边界。
    throw errorFactory(
      errorFactory === invalidLibrary
        ? "项目库不能包含符号链接"
      : "项目包不能包含符号链接",
    );
  }
  if (isTransferTemporaryArtifact(basename(source))) return;
  if (stat.isDirectory()) {
    await mkdir(target, { recursive: true, mode: stat.mode });
    for (const entry of await readdir(source)) {
      await copyPortableTree(join(source, entry), join(target, entry), { skipNames, errorFactory });
    }
    return;
  }
  if (!stat.isFile() || isSqliteArtifact(source) || skipNames.has(basename(source))) return;
  await mkdir(dirname(target), { recursive: true });
  await copyFile(source, target);
}

async function backupSqliteTree(sourceRoot, targetRoot, directory = sourceRoot) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    // 与普通文件复制保持一致：崩溃留下的 .tmp 不是持久化项目内容，不能
    // 因为其中偶然出现 SQLite 文件就重新带入导出包。
    if (isTransferTemporaryArtifact(entry.name)) continue;
    const source = join(directory, entry.name);
    if (entry.isDirectory()) {
      await backupSqliteTree(sourceRoot, targetRoot, source);
      continue;
    }
    if (!entry.isFile() || !entry.name.endsWith(".sqlite")) continue;
    const target = join(targetRoot, relative(sourceRoot, source));
    await mkdir(dirname(target), { recursive: true });
    const db = new Database(source, { readonly: true, fileMustExist: true });
    try {
      await db.backup(target);
      // 备份可能继承源库的 WAL 模式；项目包必须是单文件数据库，先切回
      // DELETE journal 再关闭副本，避免校验时重新生成 -wal/-shm 文件。
      const portableDb = new Database(target);
      try {
        portableDb.pragma("journal_mode = DELETE");
      } finally {
        portableDb.close();
      }
      await chmod(target, 0o600).catch(() => {});
    } finally {
      db.close();
    }
  }
}

async function assertProjectPackageRoot(rootPath, { requireExtension }) {
  const rootStat = await lstat(rootPath).catch(() => null);
  if (!rootStat?.isDirectory() || rootStat.isSymbolicLink()) {
    throw invalidProjectPackage("请选择有效的 .slatesync-project 项目目录");
  }
  if (requireExtension && !hasExtensionIgnoreCase(basename(rootPath), PROJECT_PACKAGE_EXTENSION)) {
    throw invalidProjectPackage("项目目录必须以 .slatesync-project 结尾");
  }
  await assertTreeContainsNoLinks(rootPath, invalidProjectPackage);
  await assertProjectPackageShape(rootPath);
}

async function readProjectPackageManifest(rootPath) {
  const manifest = await readJsonFile(
    join(rootPath, PROJECT_PACKAGE_MANIFEST),
    "无法读取 slatesync-project.json",
  );
  if (manifest.type !== "slatesync-project") {
    throw invalidProjectPackage("项目包类型无效");
  }
  const formatVersion = Number(manifest.formatVersion);
  if (!Number.isInteger(formatVersion) || formatVersion < 1) {
    throw invalidProjectPackage("项目包格式版本无效");
  }
  if (formatVersion > PROJECT_PACKAGE_FORMAT_VERSION) {
    throw invalidProjectPackage("项目包由更高版本的 SlateSync 创建，请先升级应用");
  }
  return manifest;
}

async function readProjectStorage(rootPath, suppliedProject = null) {
  const rootStat = await lstat(rootPath).catch(() => null);
  if (!rootStat?.isDirectory() || rootStat.isSymbolicLink()) {
    throw invalidProjectPackage("项目存储目录无效");
  }
  await assertTreeContainsNoLinks(rootPath, invalidProjectPackage);
  // 项目运行时可能仍持有 WAL/SHM 连接；这些 SQLite 临时文件会由在线备份重建，不能当作包内容复制。
  await assertProjectStorageShape(rootPath, { allowSqliteArtifacts: true });
  const storageManifest = await readJsonFile(
    join(rootPath, "project.json"),
    "无法读取项目存储中的 project.json",
  );
  const storageShape = normalizeStorageManifest(storageManifest);
  let project = normalizePackageProject({
    id: storageShape.id,
    libraryId: storageShape.libraryId,
    name: storageShape.name,
    description: storageShape.description,
    archivedAt: suppliedProject?.archivedAt ?? null,
    createdAt: suppliedProject?.createdAt || storageShape.createdAt,
    // Library 索引时间包含任务活动；项目 manifest 的时间只在项目设置变化时推进。
    updatedAt: suppliedProject?.updatedAt || storageShape.updatedAt,
  });
  if (suppliedProject) {
    assertSuppliedProjectMatches(project, suppliedProject, { includeTimestamps: false });
  }
  await validateProjectSnapshots(rootPath, project);
  let db;
  try {
    db = new Database(join(rootPath, SQLITE_FILENAMES.project), {
      readonly: true,
      fileMustExist: true,
    });
    if (!suppliedProject || !Object.hasOwn(suppliedProject, "archivedAt")) {
      const archiveRow = db.prepare(
        "SELECT value FROM project_meta WHERE key = ?",
      ).get("archived_at");
      if (!archiveRow) throw invalidProjectPackage("项目数据库缺少 project_meta.archived_at");
      project = normalizePackageProject({
        ...project,
        archivedAt: transferNullableTimestamp(
          parseMetadataJson(archiveRow.value, "project_meta.archived_at"),
          "归档时间",
        ),
      });
    }
    const databaseInfo = inspectProjectDatabase(db, {
      ...project,
      createdAt: storageShape.createdAt,
      updatedAt: storageShape.updatedAt,
    });
    return { project, taskCount: databaseInfo.taskCount, diagnosticCount: databaseInfo.diagnosticCount };
  } catch (error) {
    if (error?.code === "INVALID_PROJECT_PACKAGE") throw error;
    throw invalidProjectPackage(`无法读取项目存储数据库：${error.message || error}`);
  } finally {
    db?.close();
  }
}

async function validateProjectStorageDirectory(rootPath, expectedProject) {
  const storage = await readProjectStorage(rootPath, expectedProject);
  assertSuppliedProjectMatches(storage.project, expectedProject, { includeTimestamps: false });
  return storage;
}

function normalizePackageProject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalidProjectPackage("项目包清单缺少 project 对象");
  }
  return {
    id: validateProjectId(value.id),
    libraryId: validateLibraryId(value.libraryId),
    name: transferString(value.name, "项目名称", 80),
    description: transferString(value.description, "项目描述", 500),
    archivedAt: transferNullableTimestamp(value.archivedAt, "归档时间"),
    createdAt: transferTimestamp(value.createdAt, "创建时间"),
    updatedAt: transferTimestamp(value.updatedAt, "更新时间"),
  };
}

function normalizeStorageManifest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalidProjectPackage("project.json 无效");
  }
  const formatVersion = Number(value.formatVersion);
  if (!Number.isInteger(formatVersion) || formatVersion < 1) {
    throw invalidProjectPackage("project.json 格式版本无效");
  }
  if (formatVersion > PROJECT_FORMAT_VERSION) {
    throw invalidProjectPackage("项目由更高版本的 SlateSync 创建，请先升级应用");
  }
  return {
    ...value,
    id: validateProjectId(value.id),
    libraryId: validateLibraryId(value.libraryId),
    name: transferString(value.name, "项目名称", 80),
    description: transferString(value.description, "项目描述", 500),
    formatVersion,
    createdAt: transferTimestamp(value.createdAt, "创建时间"),
    updatedAt: transferTimestamp(value.updatedAt, "更新时间"),
  };
}

function validateStorageManifest(value, expectedProject) {
  const storage = normalizeStorageManifest(value);
  assertSuppliedProjectMatches({
    ...expectedProject,
    // storage manifest 按现有格式不保存 archivedAt；归档状态由包 manifest 和索引维护。
    archivedAt: expectedProject.archivedAt,
  }, {
    ...storage,
    archivedAt: expectedProject.archivedAt,
  }, { includeTimestamps: false });
  return storage;
}

function assertSuppliedProjectMatches(actual, expected, { includeTimestamps = true } = {}) {
  const fields = ["id", "libraryId", "name", "description"];
  if (includeTimestamps) fields.push("createdAt", "updatedAt");
  for (const field of fields) {
    if (expected[field] === undefined) continue;
    if (String(actual[field] ?? "") !== String(expected[field] ?? "")) {
      throw invalidProjectPackage(`项目清单字段 ${field} 不一致`);
    }
  }
  if (expected.archivedAt !== undefined && (actual.archivedAt || null) !== (expected.archivedAt || null)) {
    throw invalidProjectPackage("项目归档状态不一致");
  }
}

function inspectProjectDatabase(db, expectedProject) {
  const integrity = db.pragma("integrity_check", { simple: true });
  if (integrity !== "ok") throw invalidProjectPackage("项目数据库完整性检查失败");
  for (const table of ["project_meta", "tasks", "diagnostic_sessions", "scenario_profiles", "scenario_observations"]) {
    if (!tableExists(db, table)) throw invalidProjectPackage(`项目数据库缺少 ${table} 表`);
  }
  const metadata = Object.fromEntries(
    db.prepare("SELECT key, value FROM project_meta").all().map((row) => [row.key, row.value]),
  );
  const required = ["project_id", "library_id", "name", "description", "settings", "created_at", "updated_at", "archived_at", "schema_version"];
  for (const key of required) {
    if (!Object.hasOwn(metadata, key)) throw invalidProjectPackage(`项目数据库缺少 project_meta.${key}`);
  }
  if (metadata.project_id !== expectedProject.id || metadata.library_id !== expectedProject.libraryId) {
    throw invalidProjectPackage("项目数据库所属关系不一致");
  }
  if (metadata.name !== expectedProject.name || metadata.description !== expectedProject.description) {
    throw invalidProjectPackage("项目数据库资料与清单不一致");
  }
  if (metadata.created_at !== expectedProject.createdAt || metadata.updated_at !== expectedProject.updatedAt) {
    throw invalidProjectPackage("项目数据库时间与清单不一致");
  }
  const archivedAt = parseMetadataJson(metadata.archived_at, "project_meta.archived_at");
  if ((archivedAt || null) !== (expectedProject.archivedAt || null)) {
    throw invalidProjectPackage("项目数据库归档状态与清单不一致");
  }
  const settings = parseMetadataJson(metadata.settings, "project_meta.settings");
  if (!settings || typeof settings !== "object" || Array.isArray(settings)) {
    throw invalidProjectPackage("项目设置数据无效");
  }
  const schemaVersion = Number(metadata.schema_version);
  if (!Number.isInteger(schemaVersion) || schemaVersion < 1 || schemaVersion > PROJECT_FORMAT_VERSION) {
    throw invalidProjectPackage("项目数据库 schema 版本无效");
  }
  const taskCount = assertJsonRows(db, "tasks", expectedProject);
  const diagnosticCount = assertJsonRows(db, "diagnostic_sessions", expectedProject);
  return { taskCount, diagnosticCount };
}

function assertJsonRows(db, table, expectedProject) {
  const rows = db.prepare(`SELECT id, data_json FROM ${table}`).all();
  for (const row of rows) {
    let value;
    try {
      value = JSON.parse(row.data_json);
    } catch (error) {
      throw invalidProjectPackage(`${table}.${row.id} 的 JSON 数据无效：${error.message || error}`);
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw invalidProjectPackage(`${table}.${row.id} 的 JSON 数据必须是对象`);
    }
    if (value.projectId !== undefined && value.projectId !== expectedProject.id) {
      throw invalidProjectPackage(`${table}.${row.id} 的 projectId 不属于当前项目`);
    }
    if (value.libraryId !== undefined && value.libraryId !== expectedProject.libraryId) {
      throw invalidProjectPackage(`${table}.${row.id} 的 libraryId 不属于当前项目库`);
    }
  }
  return rows.length;
}

async function rebindImportedProject(rootPath, sourceProject, { projectId, libraryId }) {
  const projectManifestPath = join(rootPath, "project.json");
  const storageManifest = normalizeStorageManifest(await readJsonFile(
    projectManifestPath,
    "无法读取待导入项目的 project.json",
  ));
  const nextProject = {
    ...sourceProject,
    id: projectId,
    libraryId,
  };
  const nextStorageManifest = {
    ...storageManifest,
    id: projectId,
    libraryId,
    name: sourceProject.name,
    description: sourceProject.description,
  };

  let db;
  try {
    db = new Database(join(rootPath, SQLITE_FILENAMES.project));
    // 新项目暴露给 Library 前先完成重绑定；回滚日志避免暂存副本留下 WAL sidecar。
    db.pragma("journal_mode = DELETE");
    const transaction = db.transaction(() => {
      const setMeta = db.prepare(`
        INSERT INTO project_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
      `);
      setMeta.run("project_id", projectId);
      setMeta.run("library_id", libraryId);
      setMeta.run("name", sourceProject.name);
      setMeta.run("description", sourceProject.description);
      // 保留项目数据库的设置时间；Library 索引单独保存包 manifest 中的活动时间。
      setMeta.run("created_at", storageManifest.createdAt);
      setMeta.run("updated_at", storageManifest.updatedAt);
      setMeta.run("archived_at", JSON.stringify(sourceProject.archivedAt || null));

      for (const table of ["tasks", "diagnostic_sessions"]) {
        const rows = db.prepare(`SELECT id, data_json FROM ${table}`).all();
        const update = db.prepare(`UPDATE ${table} SET data_json = ? WHERE id = ?`);
        for (const row of rows) {
          update.run(rebindOwnedJson(row.data_json, { projectId, libraryId }), row.id);
        }
      }
    });
    transaction();
  } finally {
    db?.close();
  }

  await writeJsonAtomic(projectManifestPath, nextStorageManifest);
  await rewriteSnapshotDirectory(join(rootPath, "tasks"), { projectId, libraryId });
  await rewriteSnapshotDirectory(join(rootPath, "diagnostics"), { projectId, libraryId });
  return nextProject;
}

async function rewriteSnapshotDirectory(directory, { projectId, libraryId }) {
  if (!(await pathExists(directory))) return;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (isTransferTemporaryArtifact(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      // 递归处理快照子目录时继续携带新的项目库归属，避免深层数据残留旧 ID。
      await rewriteSnapshotDirectory(path, { projectId, libraryId });
      continue;
    }
    if (!entry.isFile() || !hasExtensionIgnoreCase(entry.name, ".json")) continue;
    let value;
    let raw;
    try {
      raw = await readFile(path, "utf8");
    } catch (error) {
      throw invalidProjectPackage(`${directory} 中的快照无法读取：${error.message || error}`);
    }
    try {
      value = JSON.parse(raw);
    } catch {
      // Preserve malformed compatibility snapshots verbatim; only structured
      // snapshots need ownership rebinding for the newly imported project.
      continue;
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    await writeJsonAtomic(path, { ...value, projectId, libraryId });
  }
}

function rebindOwnedJson(value, { projectId, libraryId }) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw invalidProjectPackage(`项目数据 JSON 无法重绑定：${error.message || error}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw invalidProjectPackage("项目数据 JSON 必须是对象");
  }
  // 任务和诊断快照随项目复制，两个归属字段都必须指向新项目边界。
  return JSON.stringify({ ...parsed, projectId, libraryId });
}

function parseMetadataJson(value, label) {
  try {
    return JSON.parse(value);
  } catch (error) {
    throw invalidProjectPackage(`${label} JSON 无效：${error.message || error}`);
  }
}

function validateProjectId(value) {
  const id = String(value || "");
  if (!/^project-[a-zA-Z0-9_-]+$/.test(id)) throw invalidProjectPackage("项目 ID 无效");
  return id;
}

function validateLibraryId(value) {
  const id = String(value || "");
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw invalidProjectPackage("项目库 ID 无效");
  return id;
}

function transferString(value, label, maxLength) {
  const result = String(value ?? "").trim();
  if (!result && label === "项目名称") throw invalidProjectPackage(`${label}不能为空`);
  if (result.length > maxLength) throw invalidProjectPackage(`${label}不能超过 ${maxLength} 个字符`);
  return result;
}

function transferTimestamp(value, label) {
  const result = String(value || "");
  if (!result || Number.isNaN(Date.parse(result))) throw invalidProjectPackage(`${label}无效`);
  return result;
}

function transferNullableTimestamp(value, label) {
  if (value === null || value === undefined || value === "") return null;
  return transferTimestamp(value, label);
}

function safeProjectExportName(value) {
  let name = String(value || "SlateSync Project")
    .replace(/[\\/:<>"|?*\u0000-\u001f]/g, "_")
    .trim()
    .replace(/[. ]+$/g, "");
  if (!name || name === "." || name === "..") name = "SlateSync Project";
  name = basename(name);
  // Windows device names remain reserved even with a normal-looking package
  // suffix (for example CON.slatesync-project), so make the exported name safe
  // without rejecting the project itself.
  if (/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:[. ]|$)/i.test(name)) {
    name = `_${name}`;
  }
  return name;
}

async function readJsonFile(path, message) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw invalidProjectPackage(`${message}：${error.message || error}`);
  }
}

async function writeJsonAtomic(path, value) {
  // 包内 JSON 先写临时文件再替换，避免校验或重绑定中断时留下半个清单。
  const temporaryPath = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporaryPath, JSON.stringify(value, null, 2), {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(temporaryPath, path);
}

async function assertProjectPackageShape(rootPath) {
  const entries = await readdir(rootPath, { withFileTypes: true });
  const allowed = new Set([
    PROJECT_PACKAGE_MANIFEST,
    "project.json",
    SQLITE_FILENAMES.project,
    "tasks",
    "diagnostics",
  ]);
  for (const entry of entries) {
    // 兼容旧版本在原子写入中断后留下的临时兄弟文件；复制器会主动忽略它。
    if (isTransferTemporaryArtifact(entry.name)) continue;
    if (!allowed.has(entry.name)) {
      throw invalidProjectPackage(`项目包包含不支持的文件：${entry.name}`);
    }
  }
  await assertProjectStorageShape(rootPath, { allowPackageManifest: true });
}

async function assertProjectStorageShape(
  rootPath,
  { allowPackageManifest = false, allowSqliteArtifacts = false } = {},
) {
  const entries = await readdir(rootPath, { withFileTypes: true });
  const allowed = new Set([
    "project.json",
    SQLITE_FILENAMES.project,
    "tasks",
    "diagnostics",
    ...(allowPackageManifest ? [PROJECT_PACKAGE_MANIFEST] : []),
    ...(allowSqliteArtifacts ? ["project.sqlite-wal", "project.sqlite-shm"] : []),
  ]);
  for (const entry of entries) {
    // Legacy projects may retain an interrupted atomic write. Treat the
    // artifact as disposable for both source exports and imported packages.
    if (isTransferTemporaryArtifact(entry.name)) continue;
    if (!allowed.has(entry.name)) {
      throw invalidProjectPackage(`项目存储包含不支持的文件：${entry.name}`);
    }
  }
  for (const directoryName of ["tasks", "diagnostics"]) {
    const directory = await lstat(join(rootPath, directoryName)).catch(() => null);
    if (!directory?.isDirectory() || directory.isSymbolicLink()) {
      throw invalidProjectPackage(`项目存储缺少 ${directoryName} 目录`);
    }
    for (const entry of await readdir(join(rootPath, directoryName), { withFileTypes: true })) {
      if (isTransferTemporaryArtifact(entry.name)) continue;
      if (!entry.isFile() || entry.isSymbolicLink() || !hasExtensionIgnoreCase(entry.name, ".json")) {
        throw invalidProjectPackage(`${directoryName} 只能包含 JSON 快照文件`);
      }
    }
  }
  const manifest = await lstat(join(rootPath, "project.json")).catch(() => null);
  const database = await lstat(join(rootPath, SQLITE_FILENAMES.project)).catch(() => null);
  if (!manifest?.isFile() || manifest.isSymbolicLink()) {
    throw invalidProjectPackage("项目存储缺少 project.json");
  }
  if (!database?.isFile() || database.isSymbolicLink()) {
    throw invalidProjectPackage("项目存储缺少 project.sqlite");
  }
}

async function validateProjectSnapshots(rootPath, expectedProject) {
  for (const directoryName of ["tasks", "diagnostics"]) {
    for (const entry of await readdir(join(rootPath, directoryName), { withFileTypes: true })) {
      if (isTransferTemporaryArtifact(entry.name)) continue;
      const snapshotPath = join(rootPath, directoryName, entry.name);
      let raw;
      try {
        raw = await readFile(snapshotPath, "utf8");
      } catch (error) {
        throw invalidProjectPackage(`${directoryName}/${entry.name} 无法读取：${error.message || error}`);
      }
      let snapshot;
      try {
        snapshot = JSON.parse(raw);
      } catch {
        // Legacy migration deliberately preserves malformed snapshots for a
        // later repair. Transfer them as opaque evidence instead of making the
        // whole otherwise-valid project impossible to export or import.
        continue;
      }
      if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) continue;
      if (snapshot.projectId !== undefined && snapshot.projectId !== expectedProject.id) {
        throw invalidProjectPackage(`${directoryName}/${entry.name} 的 projectId 不属于当前项目`);
      }
      if (snapshot.libraryId !== undefined && snapshot.libraryId !== expectedProject.libraryId) {
        throw invalidProjectPackage(`${directoryName}/${entry.name} 的 libraryId 不属于当前项目库`);
      }
    }
  }
}

async function assertTreeContainsNoLinks(directory, errorFactory = invalidLibrary) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const stat = await lstat(path);
    if (stat.isSymbolicLink()) {
      throw errorFactory(
        errorFactory === invalidLibrary
          ? "项目库不能包含符号链接"
          : "项目包不能包含符号链接",
      );
    }
    if (stat.isDirectory()) await assertTreeContainsNoLinks(path, errorFactory);
  }
}

async function readManifest(rootPath) {
  try {
    const manifest = JSON.parse(
      await readFile(join(rootPath, "library.json"), "utf8"),
    );
    if (!manifest || typeof manifest !== "object") throw new Error("清单为空");
    return manifest;
  } catch (error) {
    throw invalidLibrary(`无法读取 library.json：${error.message || error}`);
  }
}

function checkedProjectPath(rootPath, relativePath) {
  const projectsRoot = resolve(rootPath, "Projects");
  const candidate = resolve(rootPath, String(relativePath || ""));
  if (candidate === projectsRoot || candidate.startsWith(`${projectsRoot}${sep}`)) {
    return candidate;
  }
  throw invalidLibrary("项目索引包含越过 Library 边界的路径");
}

function assertSeparatePaths(
  source,
  target,
  message = "导出位置不能是当前项目库或其内部目录",
  code = "INVALID_LIBRARY_DESTINATION",
) {
  const sourceBoundary = `${source}${sep}`;
  const targetBoundary = `${target}${sep}`;
  if (
    source === target
    || target.startsWith(sourceBoundary)
    || source.startsWith(targetBoundary)
  ) {
    const error = new Error(message);
    error.code = code;
    throw error;
  }
}

function isSqliteArtifact(path) {
  return path.endsWith(".sqlite")
    || path.endsWith(".sqlite-wal")
    || path.endsWith(".sqlite-shm");
}

function hasExtensionIgnoreCase(value, extension) {
  return String(value || "").toLowerCase().endsWith(String(extension).toLowerCase());
}

function isTransferTemporaryArtifact(name) {
  // Atomic JSON writes use a .tmp sibling. It is safe to omit a leftover from
  // a legacy crash while keeping the durable JSON snapshot byte-for-byte.
  return String(name || "").toLowerCase().endsWith(".tmp");
}

function tableExists(db, table) {
  // 包校验只允许已知项目表，避免把未知数据库内容悄悄带入新项目。
  return Boolean(db.prepare(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
  ).get(table));
}

async function pathExists(path) {
  return Boolean(await lstat(path).catch(() => null));
}

function invalidLibrary(message) {
  const error = new Error(message);
  error.code = "INVALID_PROJECT_LIBRARY";
  return error;
}

function invalidProjectPackage(message) {
  const error = new Error(message);
  error.code = "INVALID_PROJECT_PACKAGE";
  return error;
}
