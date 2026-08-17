// Persisted user-facing app settings for the Electron build.
//
// Stores machine-level settings at <userData>/settings.json. Project content
// does not belong here: it lives inside the selected Project Library folder.
// libraryPath records the currently connected portable Library package; the
// main process validates and switches that path through native dialogs.
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_SETTINGS = Object.freeze({
  libraryPath: "",
  ocrPythonPath: "",
  ocrSetupCompleted: false,
  ocrSetupSkipped: false,
});

// Persists user-facing machine settings, mirroring the atomic write and 0600
// permissions of key-store.mjs.
export function createSettingsStore(userDataPath) {
  const filePath = join(userDataPath, "settings.json");

  return {
    async load() {
      try {
        const raw = await readFile(filePath, "utf8");
        return { ...DEFAULT_SETTINGS, ...sanitizeSettings(JSON.parse(raw)) };
      } catch {
        return { ...DEFAULT_SETTINGS };
      }
    },

    async save(settings) {
      await mkdir(userDataPath, { recursive: true });
      const data = { ...DEFAULT_SETTINGS, ...sanitizeSettings(settings) };
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

function sanitizeSettings(settings) {
  if (!settings || typeof settings !== "object") return {};
  return {
    libraryPath:
      typeof settings.libraryPath === "string" ? settings.libraryPath : "",
    ocrPythonPath:
      typeof settings.ocrPythonPath === "string" ? settings.ocrPythonPath : "",
    ocrSetupCompleted: Boolean(settings.ocrSetupCompleted),
    ocrSetupSkipped: Boolean(settings.ocrSetupSkipped),
  };
}
