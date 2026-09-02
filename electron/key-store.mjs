// Persisted provider API keys for the Electron application.
//
// Keys are stored as JSON at <userData>/provider-keys.json, written atomically
// (tmp + rename) with 0600 permissions so renderer code never handles the
// backing file directly.
import { chmod, readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join } from "node:path";

export function createKeyStore(userDataPath) {
  const filePath = join(userDataPath, "provider-keys.json");
  let pendingWrite = Promise.resolve();

  return {
    async load() {
      try {
        const raw = await readFile(filePath, "utf8");
        // Existing installations may have been created before the private
        // mode was enforced; repair them on read without touching contents.
        await chmod(filePath, 0o600).catch(() => {});
        const data = JSON.parse(raw);
        const keys = new Map();
        for (const [providerId, apiKey] of Object.entries(data)) {
          if (typeof apiKey === "string" && apiKey.trim()) {
            keys.set(providerId, apiKey);
          }
        }
        return keys;
      } catch {
        return new Map();
      }
    },

    async save(keys) {
      const data = Object.fromEntries(
        typeof keys?.entries === "function" ? keys.entries() : Object.entries(keys || {}),
      );
      const tempPath = `${filePath}.tmp`;
      // Serialize writes so two quick key edits cannot overwrite the shared
      // temporary file or publish an older snapshot after a newer one.
      const operation = pendingWrite.then(async () => {
        await mkdir(userDataPath, { recursive: true });
        await writeFile(tempPath, JSON.stringify(data, null, 2), {
          encoding: "utf8",
          mode: 0o600,
        });
        // chmod is required even when the destination already existed with a
        // broader mode; writeFile's mode option only applies on first creation.
        await chmod(tempPath, 0o600);
        await rename(tempPath, filePath);
        await chmod(filePath, 0o600);
      });
      pendingWrite = operation.catch(() => {});
      return operation;
    },
  };
}
