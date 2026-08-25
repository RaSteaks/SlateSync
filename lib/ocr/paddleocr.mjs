// PaddleOCR subprocess integration (local OCR evidence).
//
// Spawns a local Python runner (scripts/paddleocr_runner.py) over stdout JSON
// to pre-extract text/confidence/coordinates from slate pages, so the vision
// model can cross-check handwriting against OCR evidence without the pages
// ever leaving the machine. Also exposes the OCR public config and a health
// check used by the first-run wizard.
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  isRecognitionCanceled,
  recognitionCanceledError,
  throwIfRecognitionCanceled,
} from "./cancellation.mjs";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_DIR = process.env.SLATESYNC_PROJECT_DIR || join(MODULE_DIR, "..", "..");
const RUNNER_PATH = join(PROJECT_DIR, "scripts", "paddleocr_runner.py");
const DEFAULT_MODEL_CACHE_DIR = join(PROJECT_DIR, ".paddlex-cache");
const SENTINEL = "__SLATESYNC_OCR_JSON__";
const PROGRESS_SENTINEL = "__SLATESYNC_OCR_PROGRESS__";
const DEFAULT_TIMEOUT_MS = 12 * 60 * 1000;
const MAX_TIMEOUT_MS = 60 * 60 * 1000;
const TIMEOUT_PER_VIEW_MS = 45 * 1000;
const TIMEOUT_STARTUP_ALLOWANCE_MS = 2 * 60 * 1000;
const MAX_STDOUT_BYTES = 32 * 1024 * 1024;
const MAX_STDERR_BYTES = 128 * 1024;
const CACHE_LIMIT = 8;
// Allow native OCR a moment to release its models before force-killing a
// stalled subprocess after the user stops recognition.
const ABORT_KILL_GRACE_MS = 1_000;
const resultCache = new Map();
const OCR_PROFILES = {
  fast: {
    label: "快速",
    detectionModel: "PP-OCRv5_mobile_det",
    recognitionModel: "PP-OCRv5_mobile_rec",
    recognitionBatchSize: 16,
  },
  balanced: {
    label: "平衡",
    detectionModel: "PP-OCRv5_mobile_det",
    recognitionModel: "PP-OCRv5_server_rec",
    recognitionBatchSize: 8,
  },
  accurate: {
    label: "高精度",
    detectionModel: "PP-OCRv5_server_det",
    recognitionModel: "PP-OCRv5_server_rec",
    recognitionBatchSize: 4,
  },
};

export async function runPaddleOcrForPages(imageDataGroups, options = {}) {
  throwIfRecognitionCanceled(options.signal);
  const env = options.env || process.env;
  const status = paddleOcrPublicConfig(env, {
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
      warning: "没有可供 PaddleOCR 处理的页面图片。",
    };
  }

  const minimumConfidence = numberSetting(
    env.PADDLEOCR_MIN_CONFIDENCE,
    0.1,
    0,
    1,
  );
  const maxBlocksPerView = numberSetting(
    env.PADDLEOCR_MAX_BLOCKS_PER_VIEW,
    0,
    0,
    10_000,
  );
  const outputSettings = { minimumConfidence, maxBlocksPerView };
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
    modelVersion: status.modelVersion,
    profile: status.profile,
    detectionModel: status.detectionModel,
    recognitionModel: status.recognitionModel,
    recognitionBatchSize: status.recognitionBatchSize,
    language: status.language,
    device: status.device,
    minimumConfidence,
    maxBlocksPerView,
    pages: imageDataGroups.map((images, index) => ({
      pageNumber: index + 1,
      images,
    })),
  };

  try {
    const execute = options.execute || executeRunner;
    const response = await execute(payload, {
      pythonPath: status.pythonPath,
      runnerPath: RUNNER_PATH,
      timeoutMs: ocrTimeoutMs(
        env.PADDLEOCR_TIMEOUT_MS,
        totalViews,
      ),
      signal: options.signal || null,
      onProgress: (progress) => reportProgress(options.onProgress, progress),
    });
    throwIfRecognitionCanceled(options.signal);
    if (!response?.ok || !Array.isArray(response.pages)) {
      throw new Error(
        response?.error?.message || "PaddleOCR 没有返回有效的逐页结果",
      );
    }
    const normalized = normalizeOcrResult(response, status);
    if (options.cache !== false) remember(cacheKey, normalized);
    return normalized;
  } catch (error) {
    // Cancellation is terminal: treating it as an optional OCR failure would
    // incorrectly continue into the remote multimodal model stage.
    if (isRecognitionCanceled(error, options.signal)) {
      throw recognitionCanceledError();
    }
    const warning = `PaddleOCR 不可用，已降级为纯多模态识别：${error.message}`;
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

export function paddleOcrPublicConfig(env = process.env, options = {}) {
  const explicitPython = clean(env.PADDLEOCR_PYTHON);
  const workspacePython = defaultPythonPath();
  const autoEnable = options.autoEnable ?? env === process.env;
  const mode = clean(env.PADDLEOCR_ENABLED).toLowerCase() || "auto";
  const explicitlyEnabled = ["1", "true", "yes", "on"].includes(mode);
  const explicitlyDisabled = ["0", "false", "no", "off"].includes(mode);
  const pythonPath = explicitPython || workspacePython || "python3";
  const available = Boolean(explicitPython || workspacePython);
  const modelVersion = clean(env.PADDLEOCR_MODEL_VERSION) || "PP-OCRv5";
  const profile = ocrProfile(env.PADDLEOCR_PROFILE, modelVersion);
  const profileDefaults = ocrProfileDefaults(profile, modelVersion);
  const detectionModel = clean(env.PADDLEOCR_DETECTION_MODEL) ||
    profileDefaults.detectionModel;
  const recognitionModel = clean(env.PADDLEOCR_RECOGNITION_MODEL) ||
    profileDefaults.recognitionModel;
  const recognitionBatchSize = numberSetting(
    env.PADDLEOCR_RECOGNITION_BATCH_SIZE,
    profileDefaults.recognitionBatchSize,
    1,
    64,
  );
  const enabled = explicitlyDisabled
    ? false
    : explicitlyEnabled || (mode === "auto" && autoEnable && available);

  return {
    id: "paddleocr",
    label: `PaddleOCR ${profileDefaults.label}模式 + 多模态`,
    mode,
    enabled,
    available,
    required: booleanSetting(env.PADDLEOCR_REQUIRED, false),
    modelVersion,
    profile,
    profileLabel: profileDefaults.label,
    detectionModel,
    recognitionModel,
    recognitionBatchSize,
    language: clean(env.PADDLEOCR_LANGUAGE) || "ch",
    device: clean(env.PADDLEOCR_DEVICE) || "cpu",
    pythonPath,
  };
}

export function formatOcrEvidence(page, options = {}) {
  if (!page?.views?.length) return "";
  const mode = options.mode === "core" ? "core" : "full";
  const engine = String(options.engine || page.engine || "local").trim() || "local";
  const maxCharacters = Number(options.maxCharacters) || 18_000;
  const lines = [
    "<ocr_evidence>",
    `engine=${engine} page=${page.pageNumber} mode=${mode} bbox=normalized[left,top,right,bottom]`,
    "OCR is evidence, not ground truth. Verify every value against the attached images; preserve uncertain alternatives instead of guessing.",
  ];
  let characterCount = lines.join("\n").length;
  const appendLine = (line) => {
    lines.push(line);
    characterCount += line.length + 1;
  };

  let omitted = 0;
  for (const view of page.views) {
    const selected = (view.blocks || []).filter((block) =>
      includeBlock(block, view, mode),
    );
    appendLine(
      `view=${view.viewIndex} type=${view.viewType} size=${view.width}x${view.height} blocks=${selected.length}`,
    );
    for (const block of selected) {
      const box = (block.bboxNormalized || [])
        .map((value) => Number(value).toFixed(4))
        .join(",");
      const line = `#${block.order} q=${Number(block.confidence).toFixed(3)} box=[${box}] text=${JSON.stringify(block.text)}`;
      if (characterCount + line.length + 81 > maxCharacters) {
        omitted += 1;
        continue;
      }
      appendLine(line);
    }
    if (view.truncated) appendLine("view_truncated=true");
  }
  if (omitted) lines.push(`evidence_truncated=true omitted=${omitted}`);
  lines.push("</ocr_evidence>");
  return lines.join("\n");
}

export function summarizeOcrResult(result = {}) {
  // Keep diagnostics serializable even when an optional custom runner returns
  // no payload; the orchestration layer will attach the shared fallback warning.
  const source = result || {};
  const views = (source.pages || []).flatMap((page) => page.views || []);
  const blocks = views.flatMap((view) => view.blocks || []);
  return {
    enabled: Boolean(source.enabled),
    available: Boolean(source.available),
    used: Boolean(source.used),
    cacheHit: Boolean(source.cacheHit),
    engine: source.id || "paddleocr",
    model: source.modelVersion || null,
    profile: source.profile || null,
    profileLabel: source.profileLabel || null,
    detectionModel: source.detectionModel || null,
    recognitionModel: source.recognitionModel || null,
    recognitionBatchSize: Number(source.recognitionBatchSize) || null,
    device: source.device || null,
    pageCount: source.pages?.length || 0,
    viewCount: views.length,
    blockCount: blocks.length,
    lowConfidenceBlockCount: blocks.filter(
      (block) => Number(block.confidence) < 0.65,
    ).length,
    durationMs: Number(source.durationMs) || 0,
    warning: source.warning || null,
  };
}

export function clearPaddleOcrCache() {
  resultCache.clear();
}

// Validates a candidate Python/venv by running the runner's --check mode,
// which imports the PaddleOCR dependencies and reports their versions without
// doing any inference. Returns { ok, paddleVersion, paddleOcrVersion, error }.
export async function checkPaddleOcr({ pythonPath, timeoutMs = 120_000 } = {}) {
  const python = pythonPath || "python3";
  return new Promise((resolve) => {
    const child = spawn(python, [RUNNER_PATH, "--check"], {
      cwd: PROJECT_DIR,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PYTHONUNBUFFERED: "1",
        PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
        PADDLE_PDX_CACHE_HOME:
          process.env.PADDLE_PDX_CACHE_HOME || DEFAULT_MODEL_CACHE_DIR,
      },
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({
        ok: false,
        error: { code: "timeout", message: "PaddleOCR 检测超时" },
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
          message: `无法启动 Python：${error.message}`,
        },
      });
    });
    child.on("close", (code) => {
      const output = stdout.toString("utf8");
      const markerIndex = output.lastIndexOf(SENTINEL);
      if (markerIndex < 0) {
        const detail = lastUsefulLine(stderr.toString("utf8"));
        finish({
          ok: false,
          error: {
            code: "no_output",
            message: detail || `PaddleOCR 检测进程异常退出（code ${code ?? "unknown"}）`,
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
              message: `PaddleOCR 检测进程异常退出（code ${code}）`,
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
            message: `PaddleOCR 检测返回无法解析的结果：${error.message}`,
          },
        });
      }
    });
  });
}

async function executeRunner(payload, options) {
  throwIfRecognitionCanceled(options.signal);
  return new Promise((resolve, reject) => {
    const child = spawn(options.pythonPath, [options.runnerPath], {
      cwd: PROJECT_DIR,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        PYTHONUNBUFFERED: "1",
        PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
        PADDLE_PDX_CACHE_HOME:
          process.env.PADDLE_PDX_CACHE_HOME || DEFAULT_MODEL_CACHE_DIR,
      },
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
      // SIGTERM gives Python/native OCR a chance to release model resources;
      // SIGKILL guarantees the recognition lease cannot remain occupied.
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
      finish(() => reject(new Error("PaddleOCR 处理超时")));
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
      finish(() => reject(new Error(`无法启动 PaddleOCR：${error.message}`)));
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
              detail || `PaddleOCR 进程异常退出（code ${code ?? "unknown"}）`,
            ),
          );
          return;
        }
        try {
          const parsed = JSON.parse(output.slice(markerIndex + SENTINEL.length));
          if (code && parsed?.ok !== true) {
            reject(new Error(parsed?.error?.message || `PaddleOCR 退出码 ${code}`));
            return;
          }
          resolve(parsed);
        } catch (error) {
          reject(new Error(`PaddleOCR 返回无法解析的结果：${error.message}`));
        }
      });
    });

    child.stdin.on("error", (error) => {
      if (abortRequested) return;
      finish(() => reject(new Error(`无法写入 PaddleOCR 输入：${error.message}`)));
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
    profile: response.profile || status.profile,
    detectionModel: response.detectionModel || status.detectionModel,
    recognitionModel: response.recognitionModel || status.recognitionModel,
    recognitionBatchSize:
      Number(response.recognitionBatchSize) || status.recognitionBatchSize,
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
  if (!text || bboxNormalized.length !== 4 || bboxNormalized.some((v) => !Number.isFinite(v))) {
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

function includeBlock(block, view, mode) {
  if (!block?.text) return false;
  if (mode === "full" && view.viewType === "full") return true;
  return isCoreEvidence(block.text);
}

function isCoreEvidence(text) {
  const compact = String(text).replace(/\s+/g, "");
  return (
    compact.length <= 8 ||
    /\d/.test(compact) ||
    /^(?:[A-D]\d{3}|C0?\d{1,3}|A机|B机|C机|D机|场次?|镜|次|视频(?:号|码)?|景别|√|✓|✔|X|×|△|▲)$/i.test(
      compact,
    )
  );
}

function defaultPythonPath() {
  const candidates = process.platform === "win32"
    ? [join(PROJECT_DIR, ".venv-paddleocr", "Scripts", "python.exe")]
    : [join(PROJECT_DIR, ".venv-paddleocr", "bin", "python")];
  return candidates.find((candidate) => existsSync(candidate)) || "";
}

function documentCacheKey(imageDataGroups, status, outputSettings) {
  const hash = createHash("sha256");
  hashSizedValue(hash, status.modelVersion);
  hashSizedValue(hash, status.profile);
  hashSizedValue(hash, status.detectionModel);
  hashSizedValue(hash, status.recognitionModel);
  hashSizedValue(hash, String(status.recognitionBatchSize));
  hashSizedValue(hash, status.language);
  hashSizedValue(hash, status.device);
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
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1) || "";
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

function ocrProfile(value, modelVersion) {
  const normalized = clean(value).toLowerCase();
  if (normalized in OCR_PROFILES) return normalized;
  if (modelVersion !== "PP-OCRv5") return "accurate";
  return "balanced";
}

function ocrProfileDefaults(profile, modelVersion) {
  const defaults = OCR_PROFILES[profile];
  if (modelVersion === "PP-OCRv5") return defaults;
  return {
    ...defaults,
    detectionModel: "",
    recognitionModel: "",
  };
}
