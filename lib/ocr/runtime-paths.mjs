// Runtime paths shared by the local OCR engines.
//
// Electron statically imports Main modules before main.mjs can set its
// production environment. Resolve the external Resources/app root when an
// OCR function is called so both packaged engines use the same extraResources
// layout while development keeps using the repository root.
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const SOURCE_PROJECT_DIR = join(MODULE_DIR, "..", "..");

export function runtimeProjectDir(env = process.env) {
  const configured = clean(env?.SLATESYNC_PROJECT_DIR) ||
    clean(process.env.SLATESYNC_PROJECT_DIR);
  if (configured) return resolve(configured);
  if (isPackagedRuntime(env) && clean(process.resourcesPath)) {
    return resolve(process.resourcesPath, "app");
  }
  return SOURCE_PROJECT_DIR;
}

export function resolveRuntimePath(value, env = process.env) {
  const configured = clean(value);
  if (!configured) return "";
  return isAbsolute(configured)
    ? resolve(configured)
    : resolve(runtimeProjectDir(env), configured);
}

export function isPackagedRuntime(env = process.env) {
  if (booleanSetting(env?.SLATESYNC_PACKAGED, false)) return true;
  return Boolean(
    clean(process.resourcesPath) &&
      /(?:^|[\\/])app\.asar(?:[\\/]|$)/.test(MODULE_DIR),
  );
}

function booleanSetting(value, fallback) {
  const normalized = clean(value).toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}
