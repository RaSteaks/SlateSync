// macOS Vision OCR evidence layer for SlateSync.
//
// Mirrors lib/ocr/paddleocr.mjs: the Node side spawns a local Swift binary
// (scripts/vision_ocr.swift, built with swiftc into bin/vision-ocr) and talks
// to it over stdin/stdout JSON, so pages never leave the machine. Text blocks
// carry confidence and normalized coordinates in the same shape PaddleOCR
// produces, which lets the shared OCR evidence formatter and summary consume
// both engines interchangeably.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";
import {
  isRecognitionCanceled,
  recognitionCanceledError,
  throwIfRecognitionCanceled,
} from "./cancellation.mjs";
import { createOcrChildEnvironment } from "./child-environment.mjs";
import {
  isPackagedRuntime,
  resolveRuntimePath,
  runtimeProjectDir,
} from "./runtime-paths.mjs";

const SENTINEL = "__SLATESYNC_OCR_JSON__";
const PROGRESS_SENTINEL = "__SLATESYNC_OCR_PROGRESS__";
const DEFAULT_TIMEOUT_MS = 60 * 1000;
const MAX_TIMEOUT_MS = 30 * 60 * 1000;
const TIMEOUT_PER_VIEW_MS = 15 * 1000;
const TIMEOUT_STARTUP_ALLOWANCE_MS = 10 * 1000;
const MAX_STDOUT_BYTES = 32 * 1024 * 1024;
const MAX_STDERR_BYTES = 128 * 1024;
const CACHE_LIMIT = 8;
// Leave a short grace period for the Vision process to clean up before a
// forced kill guarantees a stopped recognition does not keep running.
const ABORT_KILL_GRACE_MS = 1_000;
const resultCache = new Map();
let buildPromise = null;
let toolchainAvailable = null;

export async function runVisionOcrForPages(imageDataGroups, options = {}) {
  throwIfRecognitionCanceled(options.signal);
  const env = options.env || process.env;
  const status = visionOcrPublicConfig(env, {
    autoEnable: options.autoEnable ?? env === process.env,
  });
  if (!status.enabled) {
    return {
      ...status,
      used: false,
      pages: [],
      durationMs: 0,
      warning: null,
    };
  }

  if (!Array.isArray(imageDataGroups) || !imageDataGroups.length) {
    return {
      ...status,
      used: false,
      pages: [],
      durationMs: 0,
      warning: "没有可供 Vision OCR 处理的页面图片。",
    };
  }

  const outputSettings = {
    minimumConfidence: status.minimumConfidence,
    maxBlocksPerView: status.maxBlocksPerView,
  };
  const totalViews = imageDataGroups.reduce(
    (count, group) => count + (Array.isArray(group) ? group.length : 0),
    0,
  );
  const cacheKey = documentCacheKey(imageDataGroups, status, outputSettings);
  if (options.cache !== false && resultCache.has(cacheKey)) {
    const cached = resultCache.get(cacheKey);
    resultCache.delete(cacheKey);
    resultCache.set(cacheKey, cached);
    reportProgress(options.onProgress, {
      stage: "cache-hit",
      completedViews: totalViews,
      totalViews,
      cacheHit: true,
    });
    return { ...cached, cacheHit: true };
  }

  const payload = {
    language: status.language,
    recognitionLevel: status.recognitionLevel,
    usesLanguageCorrection: status.usesLanguageCorrection,
    minimumConfidence: status.minimumConfidence,
    maxBlocksPerView: status.maxBlocksPerView,
    pages: imageDataGroups.map((images, index) => ({
      pageNumber: index + 1,
      images,
    })),
  };

  try {
    const execute = options.execute || executeRunner;
    const response = await execute(payload, {
      env,
      timeoutMs: ocrTimeoutMs(env.VISIONOCR_TIMEOUT_MS, totalViews),
      signal: options.signal || null,
      onProgress: (progress) => reportProgress(options.onProgress, progress),
    });
    throwIfRecognitionCanceled(options.signal);
    if (!response?.ok || !Array.isArray(response.pages)) {
      throw new Error(
        response?.error?.message || "Vision OCR 没有返回有效的逐页结果",
      );
    }
    const normalized = normalizeOcrResult(response, status);
    if (options.cache !== false) remember(cacheKey, normalized);
    return normalized;
  } catch (error) {
    // An aborted OCR run must never be converted into the optional-engine
    // fallback, otherwise recognition would continue with a remote model.
    if (isRecognitionCanceled(error, options.signal)) {
      throw recognitionCanceledError();
    }
    const warning = `Vision OCR 不可用，已降级为纯多模态识别：${error.message}`;
    if (status.required) {
      const wrapped = new Error(warning);
      wrapped.status = 503;
      wrapped.providerError = false;
      throw wrapped;
    }
    return {
      ...status,
      available: false,
      used: false,
      pages: [],
      durationMs: 0,
      warning,
    };
  }
}

export function visionOcrPublicConfig(env = process.env, options = {}) {
  const explicitBinary = clean(env.VISIONOCR_BINARY);
  const autoEnable = options.autoEnable ?? env === process.env;
  const mode = clean(env.VISIONOCR_ENABLED).toLowerCase() || "auto";
  const explicitlyEnabled = ["1", "true", "yes", "on"].includes(mode);
  const explicitlyDisabled = ["0", "false", "no", "off"].includes(mode);
  const language = clean(env.VISIONOCR_LANGUAGE) || "zh-Hans";
  const recognitionLevel =
    clean(env.VISIONOCR_RECOGNITION_LEVEL) === "fast" ? "fast" : "accurate";
  const usesLanguageCorrection = booleanSetting(
    env.VISIONOCR_USE_LANGUAGE_CORRECTION,
    true,
  );
  const minimumConfidence = numberSetting(
    env.VISIONOCR_MIN_CONFIDENCE,
    0.1,
    0,
    1,
  );
  const maxBlocksPerView = numberSetting(
    env.VISIONOCR_MAX_BLOCKS_PER_VIEW,
    0,
    0,
    10_000,
  );
  const binaryPath = resolveVisionBinaryPath(env);
  // Packaged applications carry a precompiled bridge in extraResources and
  // must not report a missing resource as buildable: the App bundle can be
  // read-only, and compiling into it would fail even when swiftc is installed.
  const available = existsSync(binaryPath) ||
    (!explicitBinary && !isPackagedRuntime(env) && swiftToolchainAvailable(env));
  const enabled = explicitlyDisabled
    ? false
    : explicitlyEnabled || (mode === "auto" && autoEnable && available);

  return {
    id: "vision",
    label: `Vision OCR ${recognitionLevel === "accurate" ? "高精度" : "快速"}模式 + 多模态`,
    mode,
    enabled,
    available,
    required: booleanSetting(env.VISIONOCR_REQUIRED, false),
    language,
    recognitionLevel,
    usesLanguageCorrection,
    minimumConfidence,
    maxBlocksPerView,
    binaryPath,
  };
}

export function clearVisionOcrCache() {
  resultCache.clear();
}

// A settings probe validates the same compiled bridge used for recognition,
// without requiring a user document or sending any image to a provider.
export async function checkVisionOcr({ env = process.env, timeoutMs = 120_000 } = {}) {
  let binaryPath;
  try {
    binaryPath = await ensureBinary(env);
  } catch (error) {
    return {
      ok: false,
      error: {
        code: "build_failed",
        message: `Vision OCR 检测失败：${error?.message || "无法准备本地桥接程序"}`,
      },
    };
  }

  return new Promise((resolve) => {
    const child = spawn(binaryPath, ["--check"], {
      cwd: runtimeProjectDir(env),
      stdio: ["ignore", "pipe", "pipe"],
      // Vision never needs Provider credentials; pass only the local OCR
      // runtime environment even when Main supplied a credential-rich env.
      env: createOcrChildEnvironment(env, {
        overrides: { PYTHONUNBUFFERED: "1" },
      }),
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    let timer = null;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({
        ok: false,
        error: { code: "timeout", message: "Vision OCR 检测超时" },
      });
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk, MAX_STDOUT_BYTES);
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk, MAX_STDERR_BYTES);
    });
    child.on("error", (error) => {
      finish({
        ok: false,
        error: {
          code: "spawn_failed",
          message: `无法启动 Vision OCR：${error.message}`,
        },
      });
    });
    child.on("close", (code) => {
      const output = stdout.toString("utf8");
      const markerIndex = output.lastIndexOf(SENTINEL);
      if (markerIndex < 0) {
        finish({
          ok: false,
          error: {
            code: "no_output",
            message: lastUsefulLine(stderr.toString("utf8")) ||
              `Vision OCR 检测进程异常退出（code ${code ?? "unknown"}）`,
          },
        });
        return;
      }
      try {
        const parsed = JSON.parse(output.slice(markerIndex + SENTINEL.length));
        if (code && parsed?.ok !== true) {
          finish({
            ok: false,
            error: parsed?.error || {
              code: "check_failed",
              message: `Vision OCR 检测进程异常退出（code ${code}）`,
            },
          });
          return;
        }
        finish(parsed);
      } catch (error) {
        finish({
          ok: false,
          error: {
            code: "parse_failed",
            message: `Vision OCR 检测返回无法解析的结果：${error.message}`,
          },
        });
      }
    });
  });
}

function swiftToolchainAvailable(env = process.env) {
  if (toolchainAvailable === null) {
    toolchainAvailable = (() => {
      try {
        const result = spawnSync("xcrun", ["--find", "swiftc"], {
          stdio: "ignore",
          timeout: 5_000,
          // Even the toolchain probe is an OCR child boundary; it does not
          // need access to provider credentials held by the Main process.
          env: createOcrChildEnvironment(env),
        });
        return result.status === 0;
      } catch {
        return false;
      }
    })();
  }
  return toolchainAvailable;
}

async function ensureBinary(env = process.env) {
  const explicit = clean(env.VISIONOCR_BINARY);
  const binaryPath = resolveVisionBinaryPath(env);
  if (explicit) {
    if (!existsSync(binaryPath)) {
      throw new Error(`VISIONOCR_BINARY 指向的文件不存在：${binaryPath}`);
    }
    return binaryPath;
  }
  if (existsSync(binaryPath)) return binaryPath;
  if (isPackagedRuntime(env)) {
    throw new Error(
      `打包资源中未找到 Vision OCR bridge：${binaryPath}；请重新安装或重新打包 macOS 应用。`,
    );
  }
  if (!buildPromise) {
    buildPromise = (async () => {
      const projectDir = runtimeProjectDir(env);
      const binaryDir = join(projectDir, "bin");
      const runnerPath = join(projectDir, "scripts", "vision_ocr.swift");
      mkdirSync(binaryDir, { recursive: true });
      const result = spawnSync(
        "xcrun",
        ["swiftc", "-O", "-o", binaryPath, runnerPath],
        {
          encoding: "utf8",
          timeout: 5 * 60 * 1000,
          // Native bridge compilation is local work too, so keep secrets out
          // of the compiler process when development auto-build is triggered.
          env: createOcrChildEnvironment(env),
        },
      );
      if (result.error || result.status !== 0) {
        const detail = String(result.stderr || result.stdout || "").trim();
        throw new Error(
          `swiftc 编译失败：${result.error?.message || detail.slice(-500) || "未知错误"}`,
        );
      }
      return binaryPath;
    })().finally(() => {
      buildPromise = null;
    });
  }
  return buildPromise;
}

function resolveVisionBinaryPath(env = process.env) {
  return resolveRuntimePath(
    clean(env.VISIONOCR_BINARY) || join("bin", "vision-ocr"),
    env,
  );
}

async function executeRunner(payload, options) {
  throwIfRecognitionCanceled(options.signal);
  const binaryPath = await ensureBinary(options.env || process.env);
  // A first-run build can complete after the user presses Stop; do not spawn
  // the Vision worker once that cancellation has already been requested.
  throwIfRecognitionCanceled(options.signal);
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, [], {
      cwd: runtimeProjectDir(options.env || process.env),
      stdio: ["pipe", "pipe", "pipe"],
      // Keep the native bridge isolated from Main's API-key environment.
      env: createOcrChildEnvironment(options.env || process.env, {
        overrides: { PYTHONUNBUFFERED: "1" },
      }),
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let progressRemainder = "";
    let settled = false;
    let abortRequested = false;
    let timer = null;
    let abortTimer = null;
    let onAbort = null;

    const finish = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(abortTimer);
      if (onAbort) options.signal?.removeEventListener("abort", onAbort);
      callback();
    };

    const requestAbort = () => {
      if (abortRequested || settled) return;
      abortRequested = true;
      // Vision may be inside a synchronous framework call, so escalate from a
      // graceful signal to SIGKILL if it has not exited promptly.
      try {
        child.kill("SIGTERM");
      } catch {
        // The close handler below reports the canonical cancellation result.
      }
      abortTimer = setTimeout(() => {
        if (settled || child.exitCode !== null) return;
        try {
          child.kill("SIGKILL");
        } catch {
          // A process that already exited needs no further action.
        }
      }, ABORT_KILL_GRACE_MS);
    };

    onAbort = requestAbort;
    options.signal?.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error("Vision OCR 处理超时")));
    }, options.timeoutMs);
    if (options.signal?.aborted) requestAbort();

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk, MAX_STDOUT_BYTES);
      progressRemainder = consumeProgressLines(
        progressRemainder + chunk.toString("utf8"),
        options.onProgress,
      );
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk, MAX_STDERR_BYTES);
    });
    child.on("error", (error) => {
      if (abortRequested) {
        finish(() => reject(recognitionCanceledError()));
        return;
      }
      finish(() => reject(new Error(`无法启动 Vision OCR：${error.message}`)));
    });
    child.on("close", (code) => {
      if (abortRequested) {
        finish(() => reject(recognitionCanceledError()));
        return;
      }
      finish(() => {
        consumeProgressLines(`${progressRemainder}\n`, options.onProgress);
        const output = stdout.toString("utf8");
        const markerIndex = output.lastIndexOf(SENTINEL);
        if (markerIndex < 0) {
          const detail = lastUsefulLine(stderr.toString("utf8"));
          reject(
            new Error(
              detail || `Vision OCR 进程异常退出（code ${code ?? "unknown"}）`,
            ),
          );
          return;
        }
        try {
          // The result JSON is a single compact line; anything after the
          // newline is framework noise written to stdout and must be ignored.
          const markerIndex = output.lastIndexOf(SENTINEL);
          const lineEnd = output.indexOf("\n", markerIndex);
          const jsonText = output.slice(
            markerIndex + SENTINEL.length,
            lineEnd < 0 ? undefined : lineEnd,
          );
          const parsed = JSON.parse(jsonText);
          if (code && parsed?.ok !== true) {
            reject(
              new Error(parsed?.error?.message || `Vision OCR 退出码 ${code}`),
            );
            return;
          }
          resolve(parsed);
        } catch (error) {
          reject(new Error(`Vision OCR 返回无法解析的结果：${error.message}`));
        }
      });
    });

    child.stdin.on("error", (error) => {
      if (abortRequested) return;
      finish(() => reject(new Error(`无法写入 Vision OCR 输入：${error.message}`)));
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

function consumeProgressLines(value, onProgress) {
  const lines = value.split(/\r?\n/);
  const remainder = lines.pop() || "";
  for (const line of lines) {
    if (!line.startsWith(PROGRESS_SENTINEL)) continue;
    try {
      reportProgress(
        onProgress,
        JSON.parse(line.slice(PROGRESS_SENTINEL.length)),
      );
    } catch {
      // A malformed progress update must not discard an otherwise valid OCR result.
    }
  }
  return remainder;
}

function reportProgress(callback, progress) {
  if (typeof callback !== "function") return;
  try {
    const pending = callback(progress);
    if (pending && typeof pending.catch === "function") pending.catch(() => {});
  } catch {
    // Progress observers are advisory and must never stop OCR inference.
  }
}

function normalizeOcrResult(response, status) {
  const pages = response.pages.map((page, pageIndex) => ({
    pageNumber: Number(page.pageNumber) || pageIndex + 1,
    views: Array.isArray(page.views)
      ? page.views.map((view, viewIndex) => ({
          viewIndex: Number(view.viewIndex) || viewIndex,
          viewType: view.viewType === "full" ? "full" : "core-detail",
          width: Number(view.width) || 0,
          height: Number(view.height) || 0,
          durationMs: Number(view.durationMs) || 0,
          truncated: Boolean(view.truncated),
          blocks: Array.isArray(view.blocks)
            ? view.blocks.map(normalizeBlock).filter(Boolean)
            : [],
        }))
      : [],
  }));
  return {
    ...status,
    available: true,
    used: true,
    cacheHit: false,
    modelVersion: response.modelVersion || status.modelVersion,
    language: response.language || status.language,
    recognitionLevel: response.recognitionLevel || status.recognitionLevel,
    durationMs: Number(response.durationMs) || 0,
    pages,
    warning: null,
  };
}

function normalizeBlock(block, index) {
  const text = clean(block?.text);
  const bboxNormalized = Array.isArray(block?.bboxNormalized)
    ? block.bboxNormalized.map(Number)
    : [];
  if (
    !text ||
    bboxNormalized.length !== 4 ||
    bboxNormalized.some((v) => !Number.isFinite(v))
  ) {
    return null;
  }
  return {
    order: Number.isInteger(block.order) ? block.order : index,
    text,
    confidence: Math.max(0, Math.min(1, Number(block.confidence) || 0)),
    bbox: Array.isArray(block.bbox) ? block.bbox.map(Number) : [],
    bboxNormalized,
  };
}

function documentCacheKey(imageDataGroups, status, outputSettings) {
  const hash = createHash("sha256");
  hashSizedValue(hash, status.language);
  hashSizedValue(hash, status.recognitionLevel);
  hashSizedValue(hash, String(Boolean(status.usesLanguageCorrection)));
  hashSizedValue(hash, String(outputSettings.minimumConfidence));
  hashSizedValue(hash, String(outputSettings.maxBlocksPerView));
  hashSizedValue(hash, String(imageDataGroups.length));
  for (const group of imageDataGroups) {
    const images = Array.isArray(group) ? group : [];
    hashSizedValue(hash, String(images.length));
    for (const image of images) hashSizedValue(hash, image);
  }
  return hash.digest("hex");
}

function hashSizedValue(hash, value) {
  const normalized = String(value ?? "");
  hash.update(String(Buffer.byteLength(normalized)));
  hash.update(":");
  hash.update(normalized);
  hash.update(";");
}

function ocrTimeoutMs(value, viewCount) {
  const normalized = clean(value).toLowerCase();
  if (normalized && normalized !== "auto") {
    return numberSetting(normalized, DEFAULT_TIMEOUT_MS, 10_000, MAX_TIMEOUT_MS);
  }
  return Math.min(
    MAX_TIMEOUT_MS,
    Math.max(
      DEFAULT_TIMEOUT_MS,
      TIMEOUT_STARTUP_ALLOWANCE_MS +
        Math.max(1, Number(viewCount) || 1) * TIMEOUT_PER_VIEW_MS,
    ),
  );
}

function remember(key, value) {
  resultCache.set(key, value);
  while (resultCache.size > CACHE_LIMIT) {
    resultCache.delete(resultCache.keys().next().value);
  }
}

function appendLimited(current, chunk, limit) {
  const combined = Buffer.concat([current, chunk]);
  return combined.length <= limit
    ? combined
    : combined.subarray(combined.length - limit);
}

function lastUsefulLine(value) {
  return (
    value
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .at(-1) || ""
  );
}

function booleanSetting(value, fallback) {
  const normalized = clean(value).toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}

function numberSetting(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isFinite(number)
    ? Math.max(minimum, Math.min(maximum, number))
    : fallback;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}
