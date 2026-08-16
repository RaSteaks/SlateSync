// Persisted user-facing app settings for the Electron build.
//
// Currently only the local OCR configuration (Python/venv path and setup
// flags). Stored at <userData>/settings.json with the same atomic write and
// 0600 permissions as key-store.mjs, so the OCR wizard state survives restarts.
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_SETTINGS = Object.freeze({
  ocrPythonPath: "",
  ocrSetupCompleted: false,
  ocrSetupSkipped: false,
});

// Persists user-facing app settings (currently only the local OCR
// configuration) in <userData>/settings.json, mirroring the atomic write and
// 0600 permissions of key-store.mjs.
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
    ocrPythonPath:
      typeof settings.ocrPythonPath === "string" ? settings.ocrPythonPath : "",
    ocrSetupCompleted: Boolean(settings.ocrSetupCompleted),
    ocrSetupSkipped: Boolean(settings.ocrSetupSkipped),
  };
}
