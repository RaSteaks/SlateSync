// Persisted provider API keys for the Electron application.
//
// Keys are stored as JSON at <userData>/provider-keys.json, written atomically
// (tmp + rename) with 0600 permissions so renderer code never handles the
// backing file directly.
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join } from "node:path";

export function createKeyStore(userDataPath) {
  const filePath = join(userDataPath, "provider-keys.json");

  return {
    async load() {
      try {
        const raw = await readFile(filePath, "utf8");
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
      await mkdir(userDataPath, { recursive: true });
      const data = Object.fromEntries(keys);
      const tempPath = `${filePath}.tmp`;
      await writeFile(tempPath, JSON.stringify(data, null, 2), {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(tempPath, filePath);
    },
  };
}
