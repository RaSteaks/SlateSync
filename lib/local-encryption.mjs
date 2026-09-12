// Swift LocalProjectEncryption v1 interoperability: AES-GCM with the entire
// magic/UUID/newline header as AAD, followed by nonce(12), ciphertext, tag(16).
import Database from "better-sqlite3";
import { AsyncLocalStorage } from "node:async_hooks";
import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { existsSync, readFileSync, readSync, writeFileSync, renameSync, unlinkSync, openSync, fsyncSync, closeSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ENCRYPTION_MAGIC = Buffer.from("SLATESYNC-AES-GCM-1\n");
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const keys = new Map();
const keyProviders = new AsyncLocalStorage();
// Scoped dependency injection lets synthetic integration tests exercise every
// persistence layer without creating or reading a login-keychain item.
export function withEncryptionKeyProvider(provider, operation) {
  return keyProviders.run(provider, operation);
}
let bridge;
function nativeBridge() {
  if (bridge) return bridge;
  if (process.platform !== "darwin") throw new Error("此项目库需要原 Mac 钥匙串才能解锁，请使用便携项目包进行跨平台传输");
  const db = new Database(":memory:");
  try {
    const localRoot = fileURLToPath(new URL("../", import.meta.url));
    const root = existsSync(join(localRoot, "bin/local-encryption.dylib"))
      ? localRoot : join(process.resourcesPath || localRoot, "app");
    db.loadExtension(join(root, "bin/local-encryption.dylib"));
    bridge = db;
    return db;
  } catch (error) { db.close(); throw error; }
}
export function libraryKey(id) {
  if (keyProviders.getStore()) return keyProviders.getStore()(id);
  if (!keys.has(id)) keys.set(id, nativeBridge().prepare("SELECT slatesync_key(?)").pluck().get(id));
  return keys.get(id);
}
export function encryptionIdentifier(path) {
  let parent = dirname(resolve(path));
  while (parent !== dirname(parent)) {
    try {
      const id = readFileSync(join(parent, ".slatesync-encryption"), "utf8");
      if (!uuid.test(id)) throw new Error("本地加密标识无效");
      return id;
    } catch (error) { if (error.code !== "ENOENT") throw error; }
    parent = dirname(parent);
  }
  return null;
}
export function hasEncryptedHeader(path) {
  let fd;
  try {
    fd = openSync(path, "r");
    const header = Buffer.alloc(ENCRYPTION_MAGIC.length);
    readSync(fd, header, 0, header.length, 0);
    return isEncrypted(header);
  } catch (error) { if (error.code === "ENOENT") return false; throw error; }
  finally { if (fd !== undefined) closeSync(fd); }
}
export function isEncrypted(data) { return data.subarray(0, ENCRYPTION_MAGIC.length).equals(ENCRYPTION_MAGIC); }
export function decryptFile(data, keyProvider = libraryKey, expectedId = null) {
  if (!isEncrypted(data)) return data;
  const size = ENCRYPTION_MAGIC.length + 37;
  const id = data.subarray(ENCRYPTION_MAGIC.length, size - 1).toString("ascii");
  if (data.length < size + 28 || data[size - 1] !== 10 || !uuid.test(id) || (expectedId && id !== expectedId)) throw new Error("项目加密文件头或密钥标识无效");
  const key = keyProvider(id);
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, data.subarray(size, size + 12));
    decipher.setAAD(data.subarray(0, size));
    decipher.setAuthTag(data.subarray(-16));
    return Buffer.concat([decipher.update(data.subarray(size + 12, -16)), decipher.final()]);
  } catch { throw new Error("项目数据解密校验失败，文件可能损坏；原文件未被覆盖"); }
}
export function encryptFile(data, id, keyProvider = libraryKey) {
  const header = Buffer.concat([ENCRYPTION_MAGIC, Buffer.from(`${id}\n`)]);
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyProvider(id), nonce);
  cipher.setAAD(header);
  return Buffer.concat([header, nonce, cipher.update(data), cipher.final(), cipher.getAuthTag()]);
}
export function withFileLock(path, operation) {
  const db = nativeBridge();
  const fd = db.prepare("SELECT slatesync_lock(?)").pluck().get(`${path}.lock.tmp`);
  try { return operation(); }
  finally { db.prepare("SELECT slatesync_unlock(?)").get(fd); }
}
export function atomicEncryptedWrite(path, data) {
  const temp = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temp, data, { mode: 0o600, flag: "wx" });
    const fd = openSync(temp, "r");
    try { fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(temp, path);
  } finally { try { unlinkSync(temp); } catch (error) { if (error.code !== "ENOENT") throw error; } }
}
// Existing JSON callers retain their encoding/options contract. Temporary
// siblings inherit the same marker, so atomic renames never expose plaintext.
export async function readProjectFile(path, options) {
  const data = decryptFile(await readFile(path), libraryKey, encryptionIdentifier(path));
  const encoding = typeof options === "string" ? options : options?.encoding;
  return encoding ? data.toString(encoding) : data;
}
export async function writeProjectFile(path, data, options) {
  const id = encryptionIdentifier(path);
  const encoding = typeof options === "string" ? options : options?.encoding;
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data, encoding || "utf8");
  return writeFile(path, id ? encryptFile(bytes, id) : bytes, options);
}
