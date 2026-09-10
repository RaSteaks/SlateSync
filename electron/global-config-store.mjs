// User-level non-sensitive global configuration.
//
// This file deliberately lives beside settings.json under Electron's
// userData directory, never inside a Project Library or the repository. It
// stores only validated environment overrides; provider credentials remain in
// the separate key store so this file can be backed up or inspected safely.
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { sanitizeGlobalConfig } from "./global-settings.mjs";
import { sanitizeCustomProviders } from "../lib/custom-provider.mjs";

export const GLOBAL_CONFIG_VERSION = 2;
const FILE_VERSION = GLOBAL_CONFIG_VERSION;

export function createGlobalConfigStore(userDataPath) {
  const filePath = join(userDataPath, "global-config.json");
  let pendingWrite = Promise.resolve();
  let cachedCustomProviders = null;

  return {
    async load() {
      try {
        const raw = await readFile(filePath, "utf8");
        // Repair permissions on an existing file as well as on newly-created
        // snapshots; mode is not changed by writeFile when the file exists.
        await chmod(filePath, 0o600).catch(() => {});
        const parsed = JSON.parse(raw);
        // Accept a direct object as a small forward/backward-compatibility
        // concession for early development snapshots without exposing it to
        // the rest of the application as a second storage shape.
        const values = parsed?.values && typeof parsed.values === "object"
          ? parsed.values
          : parsed;
        // v1/direct-object files contain only ordinary overrides. Treat them
        // as a v2 record with an empty registry so migration is additive and
        // never invents or moves credentials.
        const result = {
          version: FILE_VERSION,
          values: sanitizeGlobalConfig(values),
          customProviders: sanitizeCustomProviders(parsed?.customProviders),
        };
        cachedCustomProviders = result.customProviders;
        return result;
      } catch {
        cachedCustomProviders = [];
        return { version: FILE_VERSION, values: {}, customProviders: [] };
      }
    },

    async save(input) {
      const values = input?.values && typeof input.values === "object"
        ? input.values
        : input;
      const hasCustomProviders = Boolean(
        input && typeof input === "object" && Object.hasOwn(input, "customProviders"),
      );
      const requestedCustomProviders = hasCustomProviders
        ? input.customProviders
        : undefined;
      const tempPath = `${filePath}.tmp`;
      // Serializing saves avoids two renderer actions racing on the shared
      // temporary path while retaining atomic tmp+rename semantics.
      const operation = pendingWrite.then(async () => {
        let customProviders = requestedCustomProviders;
        if (!hasCustomProviders) {
          // A legacy caller that saves only ordinary values must not erase the
          // v2 registry. Read the latest snapshot when this store was created
          // before load() (or after an external writer changed the file).
          customProviders = cachedCustomProviders;
          if (customProviders == null) {
            try {
              const existing = JSON.parse(await readFile(filePath, "utf8"));
              customProviders = existing?.customProviders;
            } catch {
              customProviders = [];
            }
          }
        }
        const data = {
          version: FILE_VERSION,
          values: sanitizeGlobalConfig(values),
          customProviders: sanitizeCustomProviders(customProviders),
        };
        await mkdir(userDataPath, { recursive: true });
        await writeFile(tempPath, JSON.stringify(data, null, 2), {
          encoding: "utf8",
          mode: 0o600,
        });
        await chmod(tempPath, 0o600);
        await rename(tempPath, filePath);
        await chmod(filePath, 0o600);
        cachedCustomProviders = data.customProviders;
        return data;
      });
      pendingWrite = operation.catch(() => {});
      return operation;
    },
  };
}
