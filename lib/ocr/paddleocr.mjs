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
import { join } from "node:path";
import {
  isRecognitionCanceled,
  recognitionCanceledError,
  throwIfRecognitionCanceled,
} from "./cancellation.mjs";
import { createOcrChildEnvironment } from "./child-environment.mjs";
import { runtimeProjectDir } from "./runtime-paths.mjs";
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
let paddleWorker = null;
let paddleWorkerSequence = 0;
let paddleWorkerOperations = Promise.resolve();
// A force close invalidates operations that have not started yet. Keeping the
// generation separate from the stop flag lets a later recognition start a new
// Worker after a timeout while preventing an app-exit preload from resurrecting.
let paddleWorkerGeneration = 0;
let paddleWorkerShutdownRequested = false;
let paddleWorkerStopRequested = false;
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

// Named presets are complete, v6-only bundles. The custom branch below never
// consults these values, which keeps an existing PP-OCRv5 setup reversible and
// makes the precedence visible in one place for the UI, cache, and Worker.
export const PADDLEOCR_PRESETS = Object.freeze({
  performance: Object.freeze({
    label: "性能（质量优先）",
    modelVersion: "PP-OCRv6",
    profile: "performance",
    detectionModel: "PP-OCRv6_medium_det",
    recognitionModel: "PP-OCRv6_medium_rec",
    recognitionBatchSize: 4,
    minimumConfidence: 0.05,
    maxBlocksPerView: 0,
    textDetLimitSideLen: 1280,
  }),
  balanced: Object.freeze({
    label: "平衡（推荐）",
    modelVersion: "PP-OCRv6",
    profile: "balanced",
    detectionModel: "PP-OCRv6_small_det",
    recognitionModel: "PP-OCRv6_small_rec",
    recognitionBatchSize: 8,
    minimumConfidence: 0.1,
    maxBlocksPerView: 256,
    textDetLimitSideLen: 960,
  }),
  fast: Object.freeze({
    label: "快速（低延迟）",
    modelVersion: "PP-OCRv6",
    profile: "fast",
    detectionModel: "PP-OCRv6_tiny_det",
    recognitionModel: "PP-OCRv6_tiny_rec",
    recognitionBatchSize: 16,
    minimumConfidence: 0.25,
    maxBlocksPerView: 64,
    textDetLimitSideLen: 736,
  }),
});

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

  const minimumConfidence = status.minimumConfidence;
  const maxBlocksPerView = status.maxBlocksPerView;
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
    textDetLimitSideLen: status.textDetLimitSideLen,
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
      runnerPath: options.runnerPath || paddleRunnerPath(env),
      timeoutMs: ocrTimeoutMs(
        env.PADDLEOCR_TIMEOUT_MS,
        totalViews,
      ),
      // Pass the resolved runtime environment explicitly so user-level global
      // settings reach the Python worker without mutating process.env.
      env,
      status,
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
  const workspacePython = defaultPythonPath(env);
  const autoEnable = options.autoEnable ?? env === process.env;
  const mode = clean(env.PADDLEOCR_ENABLED).toLowerCase() || "auto";
  const explicitlyEnabled = ["1", "true", "yes", "on"].includes(mode);
  const explicitlyDisabled = ["0", "false", "no", "off"].includes(mode);
  const pythonPath = explicitPython || workspacePython || "python3";
  const available = Boolean(explicitPython || workspacePython);
  const resolved = resolvePaddleOcrParameters(env);
  const enabled = explicitlyDisabled
    ? false
    : explicitlyEnabled || (mode === "auto" && autoEnable && available);

  return {
    id: "paddleocr",
    label: `PaddleOCR ${resolved.profileLabel} + 多模态`,
    mode,
    enabled,
    available,
    required: booleanSetting(env.PADDLEOCR_REQUIRED, false),
    preset: resolved.preset,
    presetLabel: resolved.presetLabel,
    modelVersion: resolved.modelVersion,
    profile: resolved.profile,
    profileLabel: resolved.profileLabel,
    detectionModel: resolved.detectionModel,
    recognitionModel: resolved.recognitionModel,
    recognitionBatchSize: resolved.recognitionBatchSize,
    minimumConfidence: resolved.minimumConfidence,
    maxBlocksPerView: resolved.maxBlocksPerView,
    textDetLimitSideLen: resolved.textDetLimitSideLen,
    language: clean(env.PADDLEOCR_LANGUAGE) || "ch",
    device: clean(env.PADDLEOCR_DEVICE) || "cpu",
    pythonPath,
  };
}

export function resolvePaddleOcrParameters(env = {}) {
  const requestedPreset = clean(env.PADDLEOCR_PRESET).toLowerCase();
  const preset = Object.hasOwn(PADDLEOCR_PRESETS, requestedPreset)
    ? requestedPreset
    : "custom";
  const namedPreset = PADDLEOCR_PRESETS[preset];
  if (namedPreset) {
    return {
      preset,
      presetLabel: namedPreset.label,
      modelVersion: namedPreset.modelVersion,
      profile: namedPreset.profile,
      profileLabel: namedPreset.label,
      detectionModel: namedPreset.detectionModel,
      recognitionModel: namedPreset.recognitionModel,
      recognitionBatchSize: namedPreset.recognitionBatchSize,
      minimumConfidence: namedPreset.minimumConfidence,
      maxBlocksPerView: namedPreset.maxBlocksPerView,
      textDetLimitSideLen: namedPreset.textDetLimitSideLen,
    };
  }

  // Custom mode intentionally resolves each legacy field independently; a
  // missing preset must not revive stale preset values or erase v5 overrides.
  const modelVersion = normalizeModelVersion(env.PADDLEOCR_MODEL_VERSION);
  const profile = ocrProfile(env.PADDLEOCR_PROFILE, modelVersion);
  const profileDefaults = ocrProfileDefaults(profile, modelVersion);
  return {
    preset: "custom",
    presetLabel: "自定义",
    modelVersion,
    profile,
    profileLabel: profileDefaults.label,
    detectionModel:
      modelOverrideForVersion(env.PADDLEOCR_DETECTION_MODEL, modelVersion) ||
      profileDefaults.detectionModel,
    recognitionModel:
      modelOverrideForVersion(env.PADDLEOCR_RECOGNITION_MODEL, modelVersion) ||
      profileDefaults.recognitionModel,
    recognitionBatchSize: numberSetting(
      env.PADDLEOCR_RECOGNITION_BATCH_SIZE,
      profileDefaults.recognitionBatchSize,
      1,
      64,
    ),
    minimumConfidence: numberSetting(env.PADDLEOCR_MIN_CONFIDENCE, 0.1, 0, 1),
    maxBlocksPerView: numberSetting(env.PADDLEOCR_MAX_BLOCKS_PER_VIEW, 0, 0, 10_000),
    // Paddle's documented default is 960; making it explicit keeps cache keys
    // stable between an empty custom field and the equivalent named setting.
    textDetLimitSideLen: numberSetting(
      env.PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN,
      960,
      320,
      4096,
    ),
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
    preset: source.preset || null,
    presetLabel: source.presetLabel || null,
    profile: source.profile || null,
    profileLabel: source.profileLabel || null,
    detectionModel: source.detectionModel || null,
    recognitionModel: source.recognitionModel || null,
    recognitionBatchSize: Number(source.recognitionBatchSize) || null,
    textDetLimitSideLen: Number(source.textDetLimitSideLen) || null,
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

// Startup and recognition share this promise chain. It serializes model
// switches behind active requests while allowing confidence/block-only edits to
// reuse the same CPU Worker and its already-warmed pipeline.
export function preloadPaddleOcr(env = process.env, options = {}) {
  const status = options.status || paddleOcrPublicConfig(env, {
    autoEnable: options.autoEnable ?? env === process.env,
  });
  if (!status.enabled || !status.available) {
    // A disabled or invalid replacement configuration must also retire a
    // previously warm Worker; otherwise its model would keep consuming CPU.
    return closePaddleOcrWorker().then(() => ({ ...status, preloaded: false }));
  }
  const payload = runnerConfigPayload(status);
  return scheduleWorkerOperation(async (generation) => {
    throwIfRecognitionCanceled(options.signal);
    paddleWorkerStopRequested = false;
    const worker = await ensurePaddleWorker(payload, {
      ...options,
      env,
      pythonPath: status.pythonPath,
      runnerPath: options.runnerPath || paddleRunnerPath(env),
      timeoutMs: options.timeoutMs || ocrTimeoutMs(env.PADDLEOCR_TIMEOUT_MS, 1),
    });
    assertPaddleWorkerGeneration(generation, worker);
    await warmPaddleWorker(worker, payload, {
      ...options,
      timeoutMs: options.timeoutMs || ocrTimeoutMs(env.PADDLEOCR_TIMEOUT_MS, 1),
    });
    assertPaddleWorkerGeneration(generation, worker);
    return { ...status, preloaded: true };
  }, { signal: options.signal });
}

// Force mode invalidates queued work, terminates the current native process,
// and waits briefly for the serialized queue to settle. Normal mode drains
// through the same operation queue so a settings change never frees a live
// model mid-task.
export async function closePaddleOcrWorker({ force = false, deadlineAt = null, shutdown = false } = {}) {
  if (force) {
    const pendingOperations = paddleWorkerOperations;
    paddleWorkerGeneration += 1;
    if (shutdown) paddleWorkerShutdownRequested = true;
    paddleWorkerStopRequested = true;
    const worker = paddleWorker;
    paddleWorker = null;
    const closeError = paddleWorkerClosedError();
    worker?.terminate(closeError);
    // A queued preload may otherwise clear the stop flag and create a fresh
    // Python process after this close call returns. The bounded wait gives it
    // time to observe the invalidated generation without delaying shutdown.
    const waitDeadlineAt = Number.isFinite(deadlineAt)
      ? deadlineAt
      : Date.now() + ABORT_KILL_GRACE_MS;
    try {
      await raceWithDeadline(pendingOperations, { deadlineAt: waitDeadlineAt });
    } catch {
      // Force close is best-effort for callers already handling a timeout or
      // app teardown; the child has already received SIGTERM/SIGKILL handling.
    }
    if (shutdown) {
      await waitForPaddleWorkerExit(worker, waitDeadlineAt);
      // An operation that was already inside ensurePaddleWorker can create its
      // child after the force call. Shutdown mode forbids later queue entries,
      // so it is safe to catch and drain that late-created Worker as well.
      const lateWorker = paddleWorker;
      if (lateWorker && lateWorker !== worker) {
        paddleWorker = null;
        lateWorker.terminate(closeError);
        await waitForPaddleWorkerExit(lateWorker, waitDeadlineAt);
      }
    }
    return;
  }
  await scheduleWorkerOperation(async () => {
    const worker = paddleWorker;
    paddleWorker = null;
    if (worker) await closePaddleWorker(worker, { deadlineAt });
  }, { deadlineAt });
}

// Validates a candidate Python/venv by running the runner's --check mode,
// which imports the PaddleOCR dependencies and reports their versions without
// doing any inference. Returns { ok, paddleVersion, paddleOcrVersion, error }.
export async function checkPaddleOcr({
  pythonPath,
  timeoutMs = 120_000,
  env = process.env,
  signal = null,
} = {}) {
  const python = pythonPath || "python3";
  const runnerPath = paddleRunnerPath(env);
  return new Promise((resolve) => {
    const child = spawn(python, [runnerPath, "--check"], {
      cwd: runtimeProjectDir(env),
      stdio: ["ignore", "pipe", "pipe"],
      env: createOcrChildEnvironment(env, {
        overrides: {
          PYTHONUNBUFFERED: "1",
          PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
          PADDLE_PDX_CACHE_HOME:
            env.PADDLE_PDX_CACHE_HOME || paddleModelCacheDir(env),
        },
      }),
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    let abortRequested = false;
    let timer = null;
    let abortTimer = null;
    let onAbort = null;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (!abortRequested) clearTimeout(abortTimer);
      if (onAbort) signal?.removeEventListener("abort", onAbort);
      resolve(value);
    };
    const requestAbort = () => {
      if (abortRequested || settled) return;
      abortRequested = true;
      // Give Python/native OCR a short chance to release resources, then
      // force-kill a stubborn verifier; the result is settled immediately so
      // the installer UI does not wait for the full health-check timeout.
      try {
        child.kill("SIGTERM");
      } catch {
        // The canceled result below is still authoritative if the child exited.
      }
      abortTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // A process that already exited needs no further action.
        }
      }, ABORT_KILL_GRACE_MS);
      finish({
        ok: false,
        error: { code: "canceled", message: "PaddleOCR 检测已取消" },
      });
    };
    onAbort = requestAbort;
    signal?.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({
        ok: false,
        error: { code: "timeout", message: "PaddleOCR 检测超时" },
      });
    }, timeoutMs);
    if (signal?.aborted) requestAbort();

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk, MAX_STDOUT_BYTES);
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk, MAX_STDERR_BYTES);
    });
    child.on("error", (error) => {
      if (abortRequested) {
        finish({
          ok: false,
          error: { code: "canceled", message: "PaddleOCR 检测已取消" },
        });
        return;
      }
      finish({
        ok: false,
        error: {
          code: "spawn_failed",
          message: `无法启动 Python：${error.message}`,
        },
      });
    });
    child.on("close", (code) => {
      if (abortRequested) {
        finish({
          ok: false,
          error: { code: "canceled", message: "PaddleOCR 检测已取消" },
        });
        return;
      }
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

function runnerConfigPayload(status) {
  return {
    modelVersion: status.modelVersion,
    profile: status.profile,
    detectionModel: status.detectionModel,
    recognitionModel: status.recognitionModel,
    recognitionBatchSize: status.recognitionBatchSize,
    textDetLimitSideLen: status.textDetLimitSideLen,
    language: status.language,
    device: status.device,
  };
}

function workerConfigKey(payload, options) {
  const runnerEnv = options.env || process.env;
  return JSON.stringify({
    pythonPath: options.pythonPath || "python3",
    runnerPath: options.runnerPath || paddleRunnerPath(runnerEnv),
    cacheHome: runnerEnv.PADDLE_PDX_CACHE_HOME || paddleModelCacheDir(runnerEnv),
    // profile is only a legacy alias; resolved model fields are the values
    // that can actually change the native Paddle pipeline.
    modelVersion: payload.modelVersion || "",
    detectionModel: payload.detectionModel || "",
    recognitionModel: payload.recognitionModel || "",
    recognitionBatchSize: payload.recognitionBatchSize || 8,
    textDetLimitSideLen: payload.textDetLimitSideLen || 960,
    language: payload.language || "ch",
    device: payload.device || "cpu",
  });
}

function scheduleWorkerOperation(operation, { signal = null, deadlineAt = null } = {}) {
  const previous = paddleWorkerOperations;
  const generation = paddleWorkerGeneration;
  const start = () => {
    if (signal?.aborted) throw recognitionCanceledError();
    if (paddleWorkerShutdownRequested) throw paddleWorkerClosedError();
    if (Number.isFinite(deadlineAt)) remainingTimeoutMs(deadlineAt);
    return Promise.resolve().then(() => {
      assertPaddleWorkerGeneration(generation);
      return operation(generation);
    });
  };
  // Keep the internal queue occupied until the underlying operation really
  // finishes, even when the caller stops waiting after cancellation/timeout.
  // This prevents a fallback or the next model switch from running beside a
  // still-initializing native Worker.
  const scheduled = previous.then(start, start);
  paddleWorkerOperations = scheduled.catch(() => {});
  return raceWithDeadline(scheduled, { signal, deadlineAt });
}

function raceWithDeadline(promise, { signal = null, deadlineAt = null } = {}) {
  if (!signal && !Number.isFinite(deadlineAt)) return promise;
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;
    let onAbort = null;
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (onAbort) signal?.removeEventListener("abort", onAbort);
      callback(value);
    };

    onAbort = () => finish(reject, recognitionCanceledError());
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) onAbort();

    if (!settled && Number.isFinite(deadlineAt)) {
      try {
        timer = setTimeout(() => finish(reject, paddleOcrTimeoutError()), remainingTimeoutMs(deadlineAt));
      } catch (error) {
        finish(reject, error);
      }
    }

    // Always attach handlers, including when cancellation/timeout won the
    // public race, so the queued operation's eventual rejection is observed.
    promise.then(
      (value) => finish(resolve, value),
      (error) => finish(reject, error),
    );
  });
}

function operationDeadline(options) {
  if (Number.isFinite(options?.deadlineAt)) return options.deadlineAt;
  const timeoutMs = Number(options?.timeoutMs);
  return Date.now() + (Number.isFinite(timeoutMs) && timeoutMs > 0
    ? timeoutMs
    : DEFAULT_TIMEOUT_MS);
}

function remainingTimeoutMs(deadlineAt) {
  const remaining = Number(deadlineAt) - Date.now();
  if (!Number.isFinite(remaining) || remaining <= 0) {
    throw paddleOcrTimeoutError();
  }
  return Math.max(1, remaining);
}

function paddleOcrTimeoutError(message = "PaddleOCR 处理超时") {
  const error = new Error(message);
  error.code = "PADDLEOCR_TIMEOUT";
  return error;
}

function isPaddleOcrTimeout(error) {
  return error?.code === "PADDLEOCR_TIMEOUT";
}

function paddleWorkerClosedError() {
  const error = new Error("PaddleOCR Worker 已关闭");
  error.code = "PADDLEOCR_WORKER_CLOSED";
  return error;
}

function isPaddleWorkerClosed(error) {
  return error?.code === "PADDLEOCR_WORKER_CLOSED";
}

function assertPaddleWorkerGeneration(generation, worker = null) {
  if (generation === paddleWorkerGeneration) return;
  const error = paddleWorkerClosedError();
  worker?.terminate(error);
  throw error;
}

async function ensurePaddleWorker(payload, options) {
  const key = workerConfigKey(payload, options);
  if (paddleWorker && !paddleWorker.closed && paddleWorker.key === key) {
    return paddleWorker;
  }
  if (paddleWorker) {
    const previous = paddleWorker;
    paddleWorker = null;
    await closePaddleWorker(previous, { deadlineAt: options.deadlineAt });
  }
  paddleWorker = createPaddleWorker(key, options);
  return paddleWorker;
}

async function warmPaddleWorker(worker, payload, options) {
  if (worker.warmupPromise) {
    return raceWithDeadline(worker.warmupPromise, {
      deadlineAt: options.deadlineAt,
    });
  }
  // Only the model-affecting configuration is sent to warmup. Confidence and
  // block limits remain request-level filters and therefore do not duplicate
  // a native pipeline when the user tunes output evidence.
  worker.warmupPromise = worker.request("warmup", payload, {
    timeoutMs: Number.isFinite(options.deadlineAt)
      ? remainingTimeoutMs(options.deadlineAt)
      : options.timeoutMs || DEFAULT_TIMEOUT_MS,
    signal: options.signal || null,
    onProgress: options.onProgress,
  }).catch((error) => {
    worker.warmupPromise = null;
    throw error;
  });
  return raceWithDeadline(worker.warmupPromise, {
    deadlineAt: options.deadlineAt,
  });
}

async function executeRunner(payload, options) {
  const deadlineAt = operationDeadline(options);
  let operationStarted = false;
  if (options.usePersistentWorker === false) {
    return executeOneShotRunner(payload, { ...options, deadlineAt });
  }
  try {
    return await scheduleWorkerOperation(async (generation) => {
      throwIfRecognitionCanceled(options.signal);
      operationStarted = true;
      paddleWorkerStopRequested = false;
      const worker = await ensurePaddleWorker(payload, {
        ...options,
        deadlineAt,
      });
      assertPaddleWorkerGeneration(generation, worker);
      await warmPaddleWorker(worker, payload, {
        ...options,
        deadlineAt,
      });
      assertPaddleWorkerGeneration(generation, worker);
      return worker.request("recognize", payload, {
        // Every phase receives only the time left in the original OCR
        // deadline; warmup cannot silently consume a second full timeout.
        timeoutMs: remainingTimeoutMs(deadlineAt),
        signal: options.signal || null,
        onProgress: options.onProgress,
      });
    }, { signal: options.signal, deadlineAt });
  } catch (error) {
    if (isRecognitionCanceled(error, options.signal)) throw recognitionCanceledError();
    if (paddleWorkerStopRequested || isPaddleWorkerClosed(error)) throw error;
    if (isPaddleOcrTimeout(error) || deadlineExpired(deadlineAt)) {
      // A timed-out Worker may still own native model memory. Force cleanup
      // before surfacing the single operation-level timeout to the caller. A
      // request that never left the queue must not terminate another active
      // recognition that is still using the shared Worker.
      if (operationStarted) await closePaddleOcrWorker({ force: true });
      throw isPaddleOcrTimeout(error)
        ? error
        : paddleOcrTimeoutError();
    }
    // Keep the historical one-shot runner as a recovery path for missing
    // server support, broken startup, or a native Worker that exited. Close a
    // possibly half-alive Worker first so fallback never leaves two pipelines.
    try {
      await closePaddleOcrWorker({ deadlineAt });
    } catch (closeError) {
      if (isPaddleOcrTimeout(closeError) || deadlineExpired(deadlineAt)) {
        await closePaddleOcrWorker({ force: true });
        throw paddleOcrTimeoutError();
      }
      // The one-shot path is itself the final optional/required OCR boundary.
    }
    return executeOneShotRunner(payload, { ...options, deadlineAt });
  }
}

function deadlineExpired(deadlineAt) {
  return Number.isFinite(deadlineAt) && deadlineAt <= Date.now();
}

function createPaddleWorker(key, options) {
  const runnerEnv = options.env || process.env;
  const runnerPath = options.runnerPath || paddleRunnerPath(runnerEnv);
  const child = spawn(options.pythonPath || "python3", [runnerPath, "--server"], {
    cwd: runtimeProjectDir(runnerEnv),
    stdio: ["pipe", "pipe", "pipe"],
    env: createOcrChildEnvironment(runnerEnv, {
      overrides: {
        PYTHONUNBUFFERED: "1",
        PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
        PADDLE_PDX_CACHE_HOME:
          runnerEnv.PADDLE_PDX_CACHE_HOME || paddleModelCacheDir(runnerEnv),
      },
    }),
  });
  let resolveChildExit;
  const childExitPromise = new Promise((resolve) => {
    resolveChildExit = resolve;
  });
  const worker = {
    key,
    child,
    closed: false,
    closing: false,
    active: null,
    queue: [],
    pending: new Map(),
    warmupPromise: null,
    stdoutRemainder: "",
    stderr: Buffer.alloc(0),
    idleWaiters: [],
    waitForExit() {
      if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
      return childExitPromise;
    },
    request(type, payload, requestOptions = {}) {
      return new Promise((resolve, reject) => {
        if (requestOptions.signal?.aborted) {
          reject(recognitionCanceledError());
          return;
        }
        if (worker.closed || (worker.closing && type !== "shutdown")) {
          reject(new Error("PaddleOCR Worker 不可用"));
          return;
        }
        const requestId = `ocr-${++paddleWorkerSequence}`;
        const item = {
          requestId,
          type,
          payload,
          resolve,
          reject,
          timeoutMs: requestOptions.timeoutMs || DEFAULT_TIMEOUT_MS,
          signal: requestOptions.signal || null,
          onProgress: requestOptions.onProgress,
          timer: null,
          onAbort: null,
          settled: false,
        };
        item.onAbort = () => {
          if (item.settled) return;
          if (worker.active === item) {
            worker.terminate(recognitionCanceledError());
            return;
          }
          worker.queue = worker.queue.filter((queued) => queued !== item);
          worker.finish(item, recognitionCanceledError());
          worker.notifyIdle();
        };
        item.signal?.addEventListener("abort", item.onAbort, { once: true });
        worker.pending.set(requestId, item);
        worker.queue.push(item);
        worker.pump();
      });
    },
    finish(item, error, value) {
      if (!item || item.settled) return;
      item.settled = true;
      clearTimeout(item.timer);
      item.signal?.removeEventListener("abort", item.onAbort);
      worker.pending.delete(item.requestId);
      if (error) item.reject(error);
      else item.resolve(value);
    },
    pump() {
      if (worker.closed || worker.active) return;
      const item = worker.queue.shift();
      if (!item) {
        worker.notifyIdle();
        return;
      }
      if (item.settled) {
        worker.pump();
        return;
      }
      worker.active = item;
      item.timer = setTimeout(() => {
        worker.terminate(paddleOcrTimeoutError(`PaddleOCR ${item.type} 超时`));
      }, item.timeoutMs);
      const request = {
        requestId: item.requestId,
        type: item.type,
        ...(item.type === "recognize" ? { payload: item.payload } : item.payload || {}),
      };
      try {
        worker.child.stdin.write(`${JSON.stringify(request)}\n`);
      } catch (error) {
        worker.terminate(new Error(`无法写入 PaddleOCR Worker：${error.message}`));
      }
    },
    handleLine(line) {
      if (line.startsWith(PROGRESS_SENTINEL)) {
        try {
          const progress = JSON.parse(line.slice(PROGRESS_SENTINEL.length));
          const item = worker.pending.get(progress.requestId);
          if (item) reportProgress(item.onProgress, progress);
        } catch {
          // A malformed progress line is advisory and cannot invalidate a
          // later response for the same request.
        }
        return;
      }
      if (!line.startsWith(SENTINEL)) return;
      let response;
      try {
        response = JSON.parse(line.slice(SENTINEL.length));
      } catch (error) {
        worker.terminate(new Error(`PaddleOCR Worker 返回无法解析：${error.message}`));
        return;
      }
      const item = worker.pending.get(response.requestId);
      if (!item) return;
      worker.active = null;
      if (response.ok === true) worker.finish(item, null, response);
      else worker.finish(item, new Error(response.error?.message || "PaddleOCR Worker 请求失败"));
      worker.pump();
    },
    notifyIdle() {
      if (worker.active || worker.queue.length) return;
      const waiters = worker.idleWaiters.splice(0);
      for (const resolve of waiters) resolve();
    },
    waitForIdle() {
      if (!worker.active && !worker.queue.length) return Promise.resolve();
      return new Promise((resolve) => worker.idleWaiters.push(resolve));
    },
    terminate(error) {
      if (worker.closed) return;
      worker.closed = true;
      worker.active = null;
      for (const item of [...worker.pending.values()]) worker.finish(item, error);
      worker.queue = [];
      worker.notifyIdle();
      try {
        worker.child.kill("SIGTERM");
      } catch {
        // The close event is best-effort; the process is already unavailable.
      }
      const killTimer = setTimeout(() => {
        if (worker.child.exitCode === null) {
          try { worker.child.kill("SIGKILL"); } catch { /* already closed */ }
        }
      }, ABORT_KILL_GRACE_MS);
      // A normally exited Worker should not keep Node tests or app shutdown
      // alive solely for the defensive SIGKILL timer.
      killTimer.unref?.();
    },
  };

  child.stdout.on("data", (chunk) => {
    worker.stdoutRemainder += chunk.toString("utf8");
    const lines = worker.stdoutRemainder.split(/\r?\n/);
    worker.stdoutRemainder = lines.pop() || "";
    for (const line of lines) worker.handleLine(line);
  });
  child.stderr.on("data", (chunk) => {
    worker.stderr = appendLimited(worker.stderr, chunk, MAX_STDERR_BYTES);
  });
  child.stdin.on("error", (error) => {
    if (!worker.closed) worker.terminate(new Error(`无法写入 PaddleOCR Worker：${error.message}`));
  });
  child.on("error", (error) => {
    if (!worker.closed) worker.terminate(new Error(`PaddleOCR Worker 启动失败：${error.message}`));
  });
  child.on("close", (code) => {
    resolveChildExit();
    if (worker.closed) return;
    const detail = lastUsefulLine(worker.stderr.toString("utf8"));
    worker.terminate(new Error(detail || `PaddleOCR Worker 异常退出（code ${code ?? "unknown"}）`));
  });
  return worker;
}

async function closePaddleWorker(worker, { deadlineAt = null } = {}) {
  if (!worker || worker.closed) return;
  worker.closing = true;
  try {
    await raceWithDeadline(worker.waitForIdle(), { deadlineAt });
  } catch (error) {
    worker.terminate(error);
    throw error;
  }
  if (worker.closed) return;
  try {
    const timeoutMs = Number.isFinite(deadlineAt)
      ? Math.min(5_000, remainingTimeoutMs(deadlineAt))
      : 5_000;
    await worker.request("shutdown", {}, { timeoutMs });
  } catch (error) {
    if (isPaddleOcrTimeout(error)) {
      worker.terminate(error);
      throw error;
    }
    // A shutdown response is optional during app teardown; kill below is
    // bounded and prevents a stale native process from retaining the cache.
  }
  worker.terminate(new Error("PaddleOCR Worker 已关闭"));
}

async function waitForPaddleWorkerExit(worker, deadlineAt) {
  if (!worker) return;
  try {
    await raceWithDeadline(worker.waitForExit(), { deadlineAt });
  } catch {
    // SIGTERM is normally enough, but app shutdown must not leave a native
    // Python process alive when the bounded graceful window has elapsed.
    try {
      if (worker.child.exitCode === null && worker.child.signalCode === null) {
        worker.child.kill("SIGKILL");
      }
    } catch {
      // A process that exited between the check and kill is already finished.
    }
  }
}

async function executeOneShotRunner(payload, options) {
  const deadlineAt = operationDeadline(options);
  const timeoutMs = remainingTimeoutMs(deadlineAt);
  const runnerOptions = { ...options, deadlineAt, timeoutMs };
  throwIfRecognitionCanceled(runnerOptions.signal);
  const runnerEnv = runnerOptions.env || process.env;
  const runnerPath = runnerOptions.runnerPath || paddleRunnerPath(runnerEnv);
  return new Promise((resolve, reject) => {
    const child = spawn(runnerOptions.pythonPath, [runnerPath], {
      cwd: runtimeProjectDir(runnerEnv),
      stdio: ["pipe", "pipe", "pipe"],
      env: createOcrChildEnvironment(runnerEnv, {
        overrides: {
          PYTHONUNBUFFERED: "1",
          PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
          PADDLE_PDX_CACHE_HOME:
            runnerEnv.PADDLE_PDX_CACHE_HOME || paddleModelCacheDir(runnerEnv),
        },
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
      if (onAbort) runnerOptions.signal?.removeEventListener("abort", onAbort);
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
    runnerOptions.signal?.addEventListener("abort", onAbort, { once: true });
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(paddleOcrTimeoutError()));
    }, timeoutMs);
    if (runnerOptions.signal?.aborted) requestAbort();

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk, MAX_STDOUT_BYTES);
      progressRemainder = consumeProgressLines(
        progressRemainder + chunk.toString("utf8"),
        runnerOptions.onProgress,
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
        consumeProgressLines(`${progressRemainder}\n`, runnerOptions.onProgress);
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
    textDetLimitSideLen:
      Number(response.textDetLimitSideLen) || status.textDetLimitSideLen,
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

function paddleRunnerPath(env = process.env) {
  return join(runtimeProjectDir(env), "scripts", "paddleocr_runner.py");
}

function paddleModelCacheDir(env = process.env) {
  return join(runtimeProjectDir(env), ".paddlex-cache");
}

function defaultPythonPath(env = process.env) {
  const projectDir = runtimeProjectDir(env);
  const candidates = process.platform === "win32"
    ? [join(projectDir, ".venv-paddleocr", "Scripts", "python.exe")]
    : [join(projectDir, ".venv-paddleocr", "bin", "python")];
  return candidates.find((candidate) => existsSync(candidate)) || "";
}

function documentCacheKey(imageDataGroups, status, outputSettings) {
  const hash = createHash("sha256");
  hashSizedValue(hash, status.modelVersion);
  hashSizedValue(hash, status.preset);
  hashSizedValue(hash, status.profile);
  hashSizedValue(hash, status.detectionModel);
  hashSizedValue(hash, status.recognitionModel);
  hashSizedValue(hash, String(status.recognitionBatchSize));
  hashSizedValue(hash, String(status.textDetLimitSideLen));
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
  // Empty .env values are intentionally treated as unset. In particular, the
  // documented `PADDLEOCR_TEXT_DET_LIMIT_SIDE_LEN=` placeholder must keep the
  // 960-pixel custom default instead of becoming zero and clamping to 320.
  const normalized = typeof value === "string" ? value.trim() : value;
  if (normalized === "" || normalized == null) return fallback;
  const number = Number(normalized);
  return Number.isFinite(number)
    ? Math.max(minimum, Math.min(maximum, number))
    : fallback;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeModelVersion(value) {
  const normalized = clean(value);
  const lower = normalized.toLowerCase();
  if (lower === "pp-ocrv5") return "PP-OCRv5";
  if (lower === "pp-ocrv6") return "PP-OCRv6";
  // Preserve a future/locally supported version string for compatibility;
  // the Settings UI offers only versions whose model defaults it understands.
  return normalized || "PP-OCRv6";
}

function modelOverrideForVersion(value, modelVersion) {
  const model = clean(value);
  if (!model || !["PP-OCRv5", "PP-OCRv6"].includes(modelVersion)) return model;
  const modelLower = model.toLowerCase();
  const belongsToV5 = modelLower.startsWith("pp-ocrv5_");
  const belongsToV6 = modelLower.startsWith("pp-ocrv6_");
  // Hand-entered custom model IDs remain valid. Known models from the other
  // generation are ignored so a version change cannot build a mixed pipeline.
  if (modelVersion === "PP-OCRv5" && belongsToV6) return "";
  if (modelVersion === "PP-OCRv6" && belongsToV5) return "";
  return model;
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
