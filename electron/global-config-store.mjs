// User-level non-sensitive global configuration.
//
// This file deliberately lives beside settings.json under Electron's
// userData directory, never inside a Project Library or the repository. It
// stores only validated environment overrides; provider credentials remain in
// the separate key store so this file can be backed up or inspected safely.
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { sanitizeGlobalConfig } from "./global-settings.mjs";

const FILE_VERSION = 1;

export function createGlobalConfigStore(userDataPath) {
  const filePath = join(userDataPath, "global-config.json");

  return {
    async load() {
      try {
        const raw = await readFile(filePath, "utf8");
        const parsed = JSON.parse(raw);
        // Accept a direct object as a small forward/backward-compatibility
        // concession for early development snapshots without exposing it to
        // the rest of the application as a second storage shape.
        const values = parsed?.values && typeof parsed.values === "object"
          ? parsed.values
          : parsed;
        return { version: FILE_VERSION, values: sanitizeGlobalConfig(values) };
      } catch {
        return { version: FILE_VERSION, values: {} };
      }
    },

    async save(values) {
      await mkdir(userDataPath, { recursive: true });
      const data = {
        version: FILE_VERSION,
        values: sanitizeGlobalConfig(values),
      };
      const tempPath = `${filePath}.tmp`;
      await writeFile(tempPath, JSON.stringify(data, null, 2), {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(tempPath, filePath);
      return data;
    },
  };
}
