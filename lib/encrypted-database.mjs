import Database from "better-sqlite3";
import { readFileSync, existsSync, statSync } from "node:fs";
import { encryptionIdentifier, decryptFile, encryptFile, libraryKey, withFileLock, atomicEncryptedWrite, hasEncryptedHeader, isEncrypted } from "./local-encryption.mjs";

// Reuse authenticated memory snapshots while the on-disk revision is unchanged.
// Check revisions under Swift's flock before every outer operation, so another
// client's atomic replacement is visible without decrypting the whole database
// for every statement. Failed mutations discard the cached memory connection.
export function openCompatibleDatabase(path, options = {}) {
  const id = encryptionIdentifier(path);
  if (!id) {
    if (hasEncryptedHeader(path)) throw new Error("加密项目库缺少 .slatesync-encryption 标记，请恢复原项目库目录");
    return new Database(path, options);
  }
  const keyProvider = options.keyProvider || libraryKey;
  const lock = options.fileLock || withFileLock;
  // Unlock before any mutation, and never manufacture a replacement key.
  keyProvider(id);
  let active = null;
  let opened = true;
  let initialized = false;
  let cached = null;
  let revision = null;
  const diskRevision = () => {
    const stat = statSync(path, { bigint: true });
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;
  };
  const invalidate = () => {
    cached?.close();
    cached = null;
    revision = null;
  };
  function operation(writing, fn) {
    if (!opened) throw new TypeError("The database connection is not open");
    if (writing && options.readonly) throw new Error("数据库为只读");
    if (active) return fn(active);
    return lock(path, () => {
      try {
        let currentRevision = null;
        try { currentRevision = diskRevision(); }
        catch (error) {
          if (error.code !== "ENOENT" || initialized || options.fileMustExist || options.readonly) throw error;
        }
        if (!cached || revision !== currentRevision) {
          invalidate();
          let bytes;
          let encrypted = false;
          if (currentRevision !== null) {
            const stored = readFileSync(path);
            encrypted = isEncrypted(stored);
            if (encrypted) bytes = decryptFile(stored, keyProvider, id);
            else {
              // An interrupted migration may still have committed WAL pages.
              // Plaintext snapshots are never cached: the WAL can change while
              // the main file's stat remains identical.
              const source = new Database(path, { readonly: true, fileMustExist: true });
              try { bytes = source.serialize(); } finally { source.close(); }
            }
          }
          if (bytes?.length >= 20) { bytes[18] = 1; bytes[19] = 1; }
          cached = bytes ? new Database(bytes) : new Database(":memory:");
          cached.pragma("foreign_keys = ON");
          cached.pragma("temp_store = MEMORY");
          revision = encrypted ? currentRevision : null;
        }
        active = cached;
        const result = fn(cached);
        if (result?.then) throw new TypeError("加密数据库事务必须同步完成");
        if (writing) {
          atomicEncryptedWrite(path, encryptFile(cached.serialize(), id, keyProvider));
          revision = diskRevision();
        }
        initialized = true;
        return result;
      } catch (error) {
        // A failed save must never make uncommitted memory changes observable.
        invalidate();
        throw error;
      } finally { active = null; }
    });
  }

  const api = {
    get open() { return opened; },
    get inTransaction() { return active?.inTransaction || false; },
    get readonly() { return !!options.readonly; },
    get name() { return path; },
    relocatePath(nextPath) { path = nextPath; },
    close() { invalidate(); opened = false; return api; },
    exec(sql) { operation(true, db => { db.exec(sql); }); return api; },
    pragma(sql, opts) {
      // Connection tuning is applied to every memory snapshot above. A disk
      // journal/checkpoint has no meaning for authenticated memory databases.
      const tuning = /^(journal_mode|synchronous|foreign_keys|busy_timeout|temp_store|wal_checkpoint)\b/i.test(sql.trim());
      return operation(!tuning && sql.includes("="), db => db.pragma(sql, opts));
    },
    prepare(sql) {
      const state = [];
      const { reader, readonly } = operation(false, db => {
        const stmt = db.prepare(sql);
        return { reader: stmt.reader, readonly: stmt.readonly };
      });
      const invoke = (method, args) => operation(!readonly, db => {
        const stmt = db.prepare(sql);
        for (const [name, values] of state) stmt[name](...values);
        return stmt[method](...args);
      });
      const stmt = { reader, readonly, source: sql,
        run: (...args) => invoke("run", args), get: (...args) => invoke("get", args), all: (...args) => invoke("all", args),
        iterate: (...args) => invoke("all", args)[Symbol.iterator](),
      };
      for (const method of ["pluck", "raw", "expand", "safeIntegers", "bind"]) stmt[method] = (...args) => { state.push([method, args]); return stmt; };
      return stmt;
    },
    transaction(fn) {
      const wrapped = (...args) => operation(true, db => db.transaction(fn)(...args));
      for (const mode of ["deferred", "immediate", "exclusive"]) wrapped[mode] = (...args) => operation(true, db => db.transaction(fn)[mode](...args));
      return wrapped;
    },
    serialize() { return operation(false, db => db.serialize()); },
    backup(target, { portable = false } = {}) {
      // Portable exports remain plaintext even when the destination inherits a
      // local encryption marker; import staging keeps the default encrypted path.
      // Capture under the lock, then back up from its immutable memory snapshot.
      const snapshot = operation(false, db => db.serialize());
      const targetId = portable ? null : encryptionIdentifier(target);
      if (targetId) {
        // Imports staged beneath an encrypted library must never land plaintext.
        return Promise.resolve(lock(target, () => atomicEncryptedWrite(target, encryptFile(snapshot, targetId, keyProvider))));
      }
      const source = new Database(snapshot);
      return source.backup(target).finally(() => source.close());
    },
  };
  // Validate existing ciphertext now, without rewriting an authenticated file.
  // New files get a durable empty SQLite page before statements are prepared.
  operation(!existsSync(path), db => { if (!existsSync(path)) db.pragma("user_version = 0"); });
  return api;
}
