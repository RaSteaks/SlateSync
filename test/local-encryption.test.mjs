import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync, renameSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { encryptFile, decryptFile, isEncrypted, withFileLock } from "../lib/local-encryption.mjs";
import { openCompatibleDatabase } from "../lib/encrypted-database.mjs";

const id = "EEFA4048-D462-476D-A043-502CDDA4AA2D";
const key = randomBytes(32);
const keyProvider = requested => { assert.equal(requested, id); return key; };

test("Swift envelope authenticates header, nonce, ciphertext and tag", () => {
  const plain = Buffer.from('{"name":"兼容测试"}');
  const sealed = encryptFile(plain, id, keyProvider);
  assert.ok(isEncrypted(sealed));
  assert.deepEqual(decryptFile(sealed, keyProvider, id), plain);
  for (const offset of [20, 56, 70, sealed.length - 1]) {
    const corrupt = Buffer.from(sealed); corrupt[offset] ^= 1;
    assert.throws(() => decryptFile(corrupt, keyProvider, id));
  }
  assert.throws(() => decryptFile(sealed, () => randomBytes(32)), /校验失败/);
});

test("encrypted SQLite commits, rollback, concurrent handles and portable backup", async () => {
  const dir = mkdtempSync(join(tmpdir(), "slatesync-encryption-"));
  const exported = mkdtempSync(join(tmpdir(), "slatesync-portable-"));
  // Synthetic keys only: no real library or login keychain access in tests.
  const options = { keyProvider, fileLock: process.platform === "darwin" ? withFileLock : (_path, fn) => fn() };
  const path = join(dir, "library.sqlite");
  let a, b;
  try {
    writeFileSync(join(dir, ".slatesync-encryption"), id);
    a = openCompatibleDatabase(path, options);
    a.exec("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT)");
    const insert = a.prepare("INSERT INTO records(value) VALUES (?)");
    insert.run("first");
    b = openCompatibleDatabase(path, options);
    b.prepare("INSERT INTO records(value) VALUES (?)").run("second");
    assert.equal(a.prepare("SELECT count(*) FROM records").pluck().get(), 2);
    const before = readFileSync(path);
    assert.throws(a.transaction(() => { insert.run("rolled back"); throw new Error("abort"); }), /abort/);
    assert.deepEqual(readFileSync(path), before);
    a.transaction(() => { insert.run("third"); insert.run("fourth"); })();
    assert.equal(b.prepare("SELECT count(*) FROM records").pluck().get(), 4);
    assert.ok(isEncrypted(readFileSync(path)));
    assert.ok(!readdirSync(dir).some(name => /-(wal|shm)$/.test(name)));
    const target = join(exported, "project.sqlite");
    await a.backup(target);
    const portable = openCompatibleDatabase(target);
    assert.equal(portable.prepare("SELECT count(*) FROM records").pluck().get(), 4);
    portable.close();
    const readonly = openCompatibleDatabase(path, { ...options, readonly: true });
    assert.throws(() => readonly.prepare("DELETE FROM records").run(), /只读/);
    readonly.close();
    const corrupted = readFileSync(path); corrupted[corrupted.length - 1] ^= 1;
    writeFileSync(path, corrupted);
    assert.throws(() => a.prepare("SELECT * FROM records").all(), /校验失败/);
    assert.deepEqual(readFileSync(path), corrupted);
  } finally { a?.close(); b?.close(); rmSync(dir, { recursive: true, force: true }); rmSync(exported, { recursive: true, force: true }); }
});

test("Node envelopes round-trip through Swift CryptoKit in both directions", { skip: process.platform !== "darwin" }, async () => {
  const { spawnSync } = await import("node:child_process");
  const { fileURLToPath } = await import("node:url");
  const cache = mkdtempSync(join(tmpdir(), "slatesync-swift-cache-"));
  const plain = Buffer.from("Swift ⇄ Electron 合成数据");
  function swift(mode, data) {
    const result = spawnSync("xcrun", ["swift", "-module-cache-path", cache, fileURLToPath(new URL("../test-support/encryption-interop.swift", import.meta.url))], {
      input: JSON.stringify({ mode, id, key: key.toString("base64"), data: data.toString("base64") }), encoding: "utf8", timeout: 60000,
    });
    assert.equal(result.status, 0, result.stderr);
    return Buffer.from(result.stdout.trim(), "base64");
  }
  try {
    assert.deepEqual(decryptFile(swift("seal", plain), keyProvider, id), plain);
    assert.deepEqual(swift("open", encryptFile(plain, id, keyProvider)), plain);
  } finally { rmSync(cache, { recursive: true, force: true }); }
});

test("encrypted library lifecycle preserves JSON and project import/export", { skip: process.platform !== "darwin" }, async () => {
  const { withEncryptionKeyProvider } = await import("../lib/local-encryption.mjs");
  const { createProjectLibrary } = await import("../lib/project-library.mjs");
  const { createProjectRuntime } = await import("../lib/project-runtime.mjs");
  const { exportProjectLibrary, validateProjectLibrary } = await import("../lib/project-library-transfer.mjs");
  const dir = mkdtempSync(join(tmpdir(), "slatesync-encrypted-library-"));
  const root = join(dir, "original");
  mkdirSync(root);
  writeFileSync(join(root, ".slatesync-encryption"), id);
  await withEncryptionKeyProvider(keyProvider, async () => {
    let library, runtime;
    try {
      library = createProjectLibrary(root);
      const projects = await library.listProjects();
      assert.equal(projects.length, 1);
      const project = await library.createProject({ name: "加密项目" });
      runtime = createProjectRuntime(library);
      const context = await runtime.get(project.id);
      const taskId = await context.taskStore.saveTask({ filename: "synthetic.pdf", status: "completed", result: { records: [] } });
      assert.equal((await context.taskStore.loadTask(taskId)).filename, "synthetic.pdf");
      await runtime.close(); runtime = null;
      const packagePath = join(dir, "export.slatesync-project");
      await library.exportProjectPackage(project.id, packagePath);
      const imported = await library.importProjectPackage(packagePath);
      assert.ok(imported.id);
      const renamed = await library.renameLibrary("renamed");
      assert.equal((await library.listProjects()).length, 3);
      const portable = join(dir, "portable.slatesync-library");
      await exportProjectLibrary(renamed.path, portable);
      await validateProjectLibrary(portable);
      assert.ok(!readdirSync(portable).includes(".slatesync-encryption"));
      assert.ok(!isEncrypted(readFileSync(join(portable, "library.json"))));
      // Every durable JSON/SQLite file in the live library remains encrypted.
      const walk = directory => {
        for (const entry of readdirSync(directory, { withFileTypes: true })) {
          const path = join(directory, entry.name);
          if (entry.isDirectory()) walk(path);
          else if (/\.(json|sqlite)$/.test(entry.name)) assert.ok(isEncrypted(readFileSync(path)), path);
        }
      };
      walk(renamed.path);
    } finally { await runtime?.close(); await library?.close(); }
  });
  rmSync(dir, { recursive: true, force: true });
});

test("portable project and library exports stay plaintext under an encrypted ancestor", { skip: process.platform !== "darwin" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "slatesync-encrypted-boundary-"));
  const container = join(dir, "encrypted-container");
  const source = join(container, "source.slatesync-library");
  mkdirSync(source, { recursive: true });
  writeFileSync(join(container, ".slatesync-encryption"), id);
  const { withEncryptionKeyProvider } = await import("../lib/local-encryption.mjs");
  const { createProjectLibrary } = await import("../lib/project-library.mjs");
  const { exportProjectLibrary, validateProjectLibrary, validateProjectPackage } = await import("../lib/project-library-transfer.mjs");
  try {
    await withEncryptionKeyProvider(keyProvider, async () => {
      let library;
      try {
        library = createProjectLibrary(source);
        const project = await library.createProject({ name: "边界测试" });
        // The marker is above both separate paths, so this exercises inherited
        // encryption without placing an export inside its source directory.
        const packageInside = join(container, "export.slatesync-project");
        await library.exportProjectPackage(project.id, packageInside);
        assert.ok(!isEncrypted(readFileSync(join(packageInside, "project.json"))));
        assert.ok(!isEncrypted(readFileSync(join(packageInside, "project.sqlite"))));
        const packageOutside = join(dir, "exported.slatesync-project");
        renameSync(packageInside, packageOutside);
        await validateProjectPackage(packageOutside);

        const libraryInside = join(container, "export.slatesync-library");
        await exportProjectLibrary(source, libraryInside);
        assert.ok(!isEncrypted(readFileSync(join(libraryInside, "library.json"))));
        const libraryOutside = join(dir, "exported.slatesync-library");
        renameSync(libraryInside, libraryOutside);
        await validateProjectLibrary(libraryOutside);
      } finally {
        await library?.close();
      }
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("interrupted plaintext migration includes committed WAL rows", async () => {
  const { default: Database } = await import("better-sqlite3");
  const dir = mkdtempSync(join(tmpdir(), "slatesync-partial-encryption-"));
  const path = join(dir, "library.sqlite");
  let plain, encrypted;
  try {
    plain = new Database(path);
    plain.pragma("journal_mode = WAL");
    plain.exec("CREATE TABLE items(value); INSERT INTO items VALUES ('in WAL')");
    writeFileSync(join(dir, ".slatesync-encryption"), id);
    encrypted = openCompatibleDatabase(path, { keyProvider, fileLock: (_path, fn) => fn() });
    assert.equal(encrypted.prepare("SELECT value FROM items").pluck().get(), "in WAL");
    // Close the old plaintext writer before conversion; concurrent migration
    // of a pre-encryption client is not a supported cross-client workflow.
    plain.close(); plain = null;
    encrypted.prepare("INSERT INTO items VALUES (?)").run("encrypted");
    assert.ok(isEncrypted(readFileSync(path)));
    assert.equal(encrypted.prepare("SELECT count(*) FROM items").pluck().get(), 2);
  } finally { plain?.close(); encrypted?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("unchanged encrypted snapshots are reused and external commits invalidate them", () => {
  const dir = mkdtempSync(join(tmpdir(), "slatesync-encrypted-cache-"));
  const path = join(dir, "library.sqlite");
  let a, b;
  let keyReads = 0;
  const options = { keyProvider: () => { keyReads++; return key; }, fileLock: (_path, fn) => fn() };
  try {
    writeFileSync(join(dir, ".slatesync-encryption"), id);
    a = openCompatibleDatabase(path, options);
    a.exec("CREATE TABLE records(value TEXT)");
    a.prepare("INSERT INTO records VALUES (?)").run("original");
    const readsAfterWrite = keyReads;
    // This asserts the expensive operation count, not machine-dependent time.
    for (let index = 0; index < 30; index++) {
      assert.equal(a.prepare("SELECT value FROM records").pluck().get(), "original");
    }
    assert.equal(keyReads, readsAfterWrite);
    b = openCompatibleDatabase(path, options);
    b.prepare("UPDATE records SET value = ?").run("external");
    const readsAfterExternalCommit = keyReads;
    assert.equal(a.prepare("SELECT value FROM records").pluck().get(), "external");
    assert.equal(keyReads, readsAfterExternalCommit + 1);
    // A failed transaction drops its changed memory snapshot and reloads disk.
    assert.throws(a.transaction(() => {
      a.prepare("UPDATE records SET value = ?").run("discarded");
      throw new Error("abort");
    }), /abort/);
    assert.equal(a.prepare("SELECT value FROM records").pluck().get(), "external");
    rmSync(path);
    assert.throws(() => a.prepare("SELECT value FROM records").get(), { code: "ENOENT" });
  } finally { a?.close(); b?.close(); rmSync(dir, { recursive: true, force: true }); }
});
