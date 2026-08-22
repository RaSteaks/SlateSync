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
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

import {
  DEFAULT_LIBRARY_FOLDER,
  LIBRARY_FORMAT_VERSION,
} from "./project-library.mjs";
import { SQLITE_FILENAMES } from "./sqlite-store.mjs";

const LIBRARY_EXTENSION = ".slatesync-library";

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
  // Older development builds allowed an arbitrary folder as libraryPath. They
  // remain exportable, while imported/produced packages use the stable suffix.
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
    await validateProjectLibrary(staging);
    await rename(staging, target);
    return validateProjectLibrary(target);
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

async function copyPortableTree(source, target) {
  const stat = await lstat(source);
  if (stat.isSymbolicLink()) throw invalidLibrary("项目库不能包含符号链接");
  if (stat.isDirectory()) {
    await mkdir(target, { recursive: true, mode: stat.mode });
    for (const entry of await readdir(source)) {
      await copyPortableTree(join(source, entry), join(target, entry));
    }
    return;
  }
  if (!stat.isFile() || isSqliteArtifact(source)) return;
  await mkdir(dirname(target), { recursive: true });
  await copyFile(source, target);
}

async function backupSqliteTree(sourceRoot, targetRoot, directory = sourceRoot) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
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
      await chmod(target, 0o600).catch(() => {});
    } finally {
      db.close();
    }
  }
}

async function assertTreeContainsNoLinks(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const stat = await lstat(path);
    if (stat.isSymbolicLink()) throw invalidLibrary("项目库不能包含符号链接");
    if (stat.isDirectory()) await assertTreeContainsNoLinks(path);
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

function assertSeparatePaths(source, target) {
  const sourceBoundary = `${source}${sep}`;
  const targetBoundary = `${target}${sep}`;
  if (
    source === target
    || target.startsWith(sourceBoundary)
    || source.startsWith(targetBoundary)
  ) {
    const error = new Error("导出位置不能是当前项目库或其内部目录");
    error.code = "INVALID_LIBRARY_DESTINATION";
    throw error;
  }
}

function isSqliteArtifact(path) {
  return path.endsWith(".sqlite")
    || path.endsWith(".sqlite-wal")
    || path.endsWith(".sqlite-shm");
}

async function pathExists(path) {
  return Boolean(await lstat(path).catch(() => null));
}

function invalidLibrary(message) {
  const error = new Error(message);
  error.code = "INVALID_PROJECT_LIBRARY";
  return error;
}
