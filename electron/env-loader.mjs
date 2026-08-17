// Environment and settings helpers for the Electron main process.
//
// Development builds read a project-local .env while packaged builds read the
// application data copy. The remaining helpers normalize Electron runtime
// settings and enforce recognition concurrency.
import { readFile } from "node:fs/promises";

export async function loadLocalEnv(path) {
  let contents;
  try {
    contents = await readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

export function createTaskLimiter(limit) {
  let active = 0;
  return {
    limit,
    get active() {
      return active;
    },
    acquire() {
      if (active >= limit) {
        const error = new Error(
          `正在处理 ${active} 个识别任务，请稍后重试`,
        );
        error.status = 429;
        throw error;
      }
      active += 1;
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
      };
    },
  };
}

export function integerSetting(value, fallback, minimum, maximum, name) {
  if (value == null || String(value).trim() === "") return fallback;
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < minimum || numeric > maximum) {
    throw new Error(`${name} 必须是 ${minimum}–${maximum} 之间的整数`);
  }
  return numeric;
}

export function cleanSetting(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function electronSettings(env) {
  return {
    maxBodyBytes:
      integerSetting(env.MAX_BODY_MB, 80, 20, 200, "MAX_BODY_MB") *
      1024 *
      1024,
    maxConcurrentRecognitions: integerSetting(
      env.MAX_CONCURRENT_RECOGNITIONS,
      1,
      1,
      16,
      "MAX_CONCURRENT_RECOGNITIONS",
    ),
  };
}
