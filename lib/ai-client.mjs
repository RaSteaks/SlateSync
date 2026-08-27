// Vision-LLM slate recognition client.
//
// Sends preprocessed slate pages to a configured provider (OpenAI, OpenRouter,
// Token Plan, DashScope, or any OpenAI-compatible endpoint) and returns
// structured records validated against lib/schema.mjs. Handles image
// preprocessing, optional local OCR evidence (PaddleOCR / macOS Vision),
// multi-stage "high accuracy" audit, page ordering, progress events, and cost
// tracking. PDF bytes are rasterized before this module is called; providers
// receive page images only.
import { MODELS, resolveModel, resolveProvider } from "./config.mjs";
import { Agent, setGlobalDispatcher } from "undici";
import {
  formatOcrEvidence,
  runPaddleOcrForPages,
  summarizeOcrResult,
} from "./ocr/paddleocr.mjs";
import {
  runVisionOcrForPages,
} from "./ocr/vision.mjs";
import { resolveOcrSelection } from "./ocr/selection.mjs";
import {
  recognitionCanceledError,
  throwIfRecognitionCanceled,
} from "./ocr/cancellation.mjs";
import { parseCanonicalMaterialKey } from "../public/metadata-common.js";
import { detectSlateSequenceAnomalies } from "../public/resolve-csv.js";
import {
  CORE_AUDIT_SYSTEM_PROMPT,
  CORE_REVIEW_SYSTEM_PROMPT,
  CORE_SLATE_SCHEMA,
  commentsInstruction,
  fieldFormatInstruction,
  formatSlateResultFields,
  normalizeSlateResult,
  SLATE_SCHEMA,
  SYSTEM_PROMPT,
} from "./schema.mjs";
import {
  createScenarioObservation,
  scenarioPromptInstruction,
} from "./scenario/profile.mjs";

const DEFAULT_REQUEST_TIMEOUT_MS = 180_000;
const DEFAULT_REQUEST_MAX_RETRIES = 1;
const DEFAULT_PAGE_CONCURRENCY = 2;

// Node's built-in fetch (undici) waits only 300s for response headers by
// default; give it headroom above MODEL_REQUEST_TIMEOUT_MS so slow multimodal
// generations are cut by our own timeout instead of the socket layer.
export function configureModelHttpAgent(env = process.env) {
  const timeoutMs = modelRequestTimeoutMs(env);
  setGlobalDispatcher(
    new Agent({
      headersTimeout: timeoutMs + 60_000,
      bodyTimeout: timeoutMs + 60_000,
    }),
  );
}

const OCR_ENGINE_NAMES = {
  vision: "Vision OCR",
  paddleocr: "PaddleOCR",
  custom: "本地 OCR",
};

// Keep the optional-OCR fallback wording stable across progress, persisted
// task summaries, diagnostics, and the final result warning list.
const OCR_DEGRADED_WARNING =
  "本地 OCR 不可用，已改用页面图片直接识别；识别精度可能下降。";

function withCustomPrompt(systemPrompt, customPrompt, slateCsvContext) {
  const parts = [systemPrompt];
  const context = String(customPrompt || "").trim();
  if (context) {
    parts.push(`项目背景补充（用户提供，帮助理解场记单内容）：\n${context}`);
  }
  if (slateCsvContext) {
    parts.push(slateCsvContext);
  }
  return parts.join("\n\n");
}

function buildSlateCsvContext(slateCsvRecords) {
  if (!Array.isArray(slateCsvRecords) || !slateCsvRecords.length) return "";
  const lines = [
    "以下是场记系统导出的高可信度场记记录（Scene/Shot/Take 以场记系统为准）：",
    "",
  ];
  for (const record of slateCsvRecords) {
    const parts = [];
    if (record.materialKey) parts.push(`素材=${record.materialKey}`);
    if (record.scene) parts.push(`场=${record.scene}`);
    if (record.shot) parts.push(`镜=${record.shot}`);
    if (record.take) parts.push(`次=${record.take}`);
    if (record.comments) parts.push(`状态=${record.comments}`);
    if (parts.length) lines.push(parts.join(" "));
  }
  lines.push("");
  lines.push(
    "以上场记记录的 Scene/Shot/Take 是高可信度的。识别场记单图片时，如果图片中的识别结果与场记记录不一致，以场记记录为准修正 Scene/Shot/Take。场记记录中没有的素材，仍按图片识别结果返回。",
  );
  return lines.join("\n");
}

export async function recognizeSlate(
  {
    providerId,
    modelId,
    imageDataUrl,
    imageDataUrls,
    imageDataGroups,
    filename = "slate",
    accuracyMode = "standard",
    fieldFormats,
    comments,
    scenarioId,
    customPrompt,
    slateCsvRecords,
  },
  options = {},
) {
  if (Object.hasOwn(arguments[0] || {}, "pdfDataUrl")) {
    throw clientError(
      "原始 PDF 直传已停用，请先在本地将 PDF 转为逐页图片后再识别。",
      400,
    );
  }
  const env = options.env || process.env;
  const fetchImpl = options.fetchImpl || fetch;
  const signal = options.signal || null;
  throwIfRecognitionCanceled(signal);
  const reportProgress = createProgressReporter(options.onProgress);
  const capture = options.capture || null;
  const resolvedProvider = resolveProvider(providerId, env);

  if (!resolvedProvider) {
    throw clientError("未知 API 服务商", 400);
  }
  const missingConfiguration = resolvedProvider.requiredEnv.filter(
    (key) => !String(env[key] || "").trim(),
  );
  if (missingConfiguration.length) {
    throw clientError(`尚未配置 ${missingConfiguration.join("、")}`, 400);
  }
  const provider = {
    ...resolvedProvider,
    baseUrl: normalizeBaseUrl(
      env[resolvedProvider.baseUrlEnv] || resolvedProvider.defaultBaseUrl,
      resolvedProvider.baseUrlEnv,
    ),
    timeoutMs: modelRequestTimeoutMs(env),
    maxRetries: modelRequestMaxRetries(env),
  };
  const model = resolveModel(providerId, modelId, env);
  if (!model) {
    throw clientError("所选模型不支持当前 API 服务商", 400);
  }
  const images = Array.isArray(imageDataUrls)
    ? imageDataUrls
    : imageDataUrl
      ? [imageDataUrl]
      : [];
  const imageGroups = Array.isArray(imageDataGroups)
    ? imageDataGroups
    : images.map((image) => [image]);
  const highAccuracy = accuracyMode === "high";
  if (
    imageGroups.length < 1 ||
    imageGroups.length > 20 ||
    !imageGroups.every(
      (group) =>
        Array.isArray(group) &&
        group.length >= 1 &&
        group.length <= 3 &&
        group.every(isSupportedImageDataUrl),
    )
  ) {
    throw clientError("只支持 1–20 页图片，每页可包含 1–3 张 JPEG、PNG 或 WebP 视图", 400);
  }
  const normalizedPageCount = imageGroups.length;

  const apiKey = String(env[provider.envKey]).trim();

  const slateCsvContext = buildSlateCsvContext(slateCsvRecords);

  const startedAt = Date.now();
  reportProgress({
    phase: "starting",
    percent: 2,
    message: `正在准备 ${normalizedPageCount} 页识别任务`,
    completed: 0,
    total: normalizedPageCount,
  });
  const ocrEngine = resolveOcrEngine(env, options);
  const ocrImpl = ocrEngine.impl;
  const engineName = OCR_ENGINE_NAMES[ocrEngine.meta.id] || "本地 OCR";
  reportProgress({
    phase: "ocr",
    percent: 5,
    message: `正在启动 ${engineName} 文字与坐标提取`,
  });
  if (capture) {
    capture.setRequestInfo({
      filename,
      provider: providerId,
      model: modelId,
      pageCount: normalizedPageCount,
    });
  }
  let ocrResult;
  try {
    // Local OCR always completes before the first provider request. Even an
    // optional-engine failure returns here as a page-image fallback result.
    ocrResult = await ocrImpl(imageGroups, {
      env,
      // Local OCR implementations receive the same signal as model requests
      // so a stop action kills their worker before any model request can start.
      signal,
      autoEnable: options.ocrAutoEnable ?? env === process.env,
      onProgress: (progress) => {
        const completed = Math.max(0, Number(progress?.completedViews) || 0);
        const total = Math.max(0, Number(progress?.totalViews) || 0);
        const ratio = total ? Math.min(1, completed / total) : 0;
        reportProgress({
          phase: "ocr",
          percent: Math.round(5 + ratio * 30),
          message: progress?.cacheHit
            ? `已复用本地 ${engineName} 结果`
            : completed
              ? `${engineName} 已处理 ${completed}/${total} 个页面视图`
              : `${engineName} 模型已就绪，开始逐视图识别`,
          completed,
          total,
          pageNumber: Number(progress?.pageNumber) || null,
          viewIndex: Number.isInteger(progress?.viewIndex)
            ? progress.viewIndex
            : null,
          cacheHit: Boolean(progress?.cacheHit),
        });
      },
    });
  } catch (error) {
    // Third-party OCR implementations can surface platform-specific abort
    // errors. Normalize those only when the caller's signal caused them.
    if (signal?.aborted) throw recognitionCanceledError();
    if (ocrEngine.meta.required) {
      const requiredEnv = ocrEngine.meta.id === "vision"
        ? "VISIONOCR_REQUIRED"
        : "PADDLEOCR_REQUIRED";
      const wrapped = clientError(
        `${error?.message || `${engineName} 失败`}；请修复本地 OCR 的安装、路径或配置，或关闭 ${requiredEnv} 后重试。`,
        503,
      );
      wrapped.providerError = false;
      wrapped.cause = error;
      throw wrapped;
    }
    // The built-in runners normally convert optional failures themselves, but
    // keep this boundary defensive for injected/custom OCR implementations so
    // an unexpected rejection still degrades to page-image recognition.
    ocrResult = {
      ...ocrEngine.meta,
      available: false,
      used: false,
      pages: [],
      durationMs: 0,
      warning: `${engineName} 不可用：${error?.message || "未知错误"}`,
    };
  }
  throwIfRecognitionCanceled(signal);
  const summarizedOcr = summarizeOcrResult(ocrResult);
  const ocrDegradedWarning = summarizedOcr.used && summarizedOcr.blockCount > 0
    ? null
    : OCR_DEGRADED_WARNING;
  // Persist the same warning that was shown during OCR so a completed task
  // and its diagnostic session do not lose the reason for image-only fallback.
  const ocrSummary = {
    ...summarizedOcr,
    warning: ocrDegradedWarning || summarizedOcr.warning || null,
  };
  if (ocrEngine.meta.required && (!ocrSummary.used || ocrSummary.blockCount === 0)) {
    throw clientError(
      `${engineName} 已设置为必需模式，但没有返回有效结果；请修复本地 OCR 配置后重试，或关闭 ${engineName === "Vision OCR" ? "VISIONOCR_REQUIRED" : "PADDLEOCR_REQUIRED"}。`,
      503,
    );
  }
  if (capture) capture.setOcrResult(ocrSummary, ocrResult);
  const scenarioSelection = await resolveScenarioSelection({
    scenarioStore: options.scenarioStore,
    scenarioId,
    ocrResult,
    filename,
    fieldFormats,
    comments,
  });
  throwIfRecognitionCanceled(signal);
  // Project settings are the final Electron output contract. Profile output
  // metadata cannot silently change Scene/Shot/Take formatting inside an
  // isolated project.
  const effectiveFieldFormats = options.projectScopedOutput
    ? fieldFormats
    : scenarioSelection?.profile?.output?.resolve?.fieldFormats || fieldFormats;
  const effectiveComments = options.projectScopedOutput
    ? comments
    : scenarioSelection?.profile?.output?.resolve?.comments || comments;
  const scenarioNote = scenarioSelection?.profile
    ? scenarioPromptInstruction(scenarioSelection.profile)
    : "";
  // Optional user-supplied background context is appended to every stage's
  // system prompt so the model understands the production without overriding
  // the recognition rules. Learned structure hints are appended after the
  // fixed safety rules and never replace the canonical output schema.
  const formatNote =
    fieldFormatInstruction(effectiveFieldFormats) +
    commentsInstruction(effectiveComments);
  const customContext = withCustomPrompt(SYSTEM_PROMPT, customPrompt, slateCsvContext) + formatNote + scenarioNote;
  const auditContext = withCustomPrompt(CORE_AUDIT_SYSTEM_PROMPT, customPrompt, slateCsvContext) + formatNote + scenarioNote;
  const reviewContext = withCustomPrompt(CORE_REVIEW_SYSTEM_PROMPT, customPrompt, slateCsvContext) + formatNote + scenarioNote;
  reportProgress({
    phase: "ocr",
    percent: 35,
    warning: ocrDegradedWarning,
    message: ocrDegradedWarning
      ? ocrDegradedWarning
      : ocrSummary.used
      ? `${engineName} 完成：提取 ${ocrSummary.blockCount} 个文字块`
      : `未启用 ${engineName}，继续使用页面图片识别`,
  });

  let completedPages = 0;
  const pageProgressPercent = () =>
    Math.round(35 + (completedPages / imageGroups.length) * 60);
  const completePage = (pageNumber) => {
    completedPages += 1;
    reportProgress({
      phase: "page-complete",
      percent: pageProgressPercent(),
      message: `已完成第 ${pageNumber} 页（${completedPages}/${imageGroups.length} 页）`,
      pageNumber,
      completed: completedPages,
      total: imageGroups.length,
    });
  };
  const pages = await mapWithConcurrency(
    imageGroups,
    pageConcurrency(env),
    async (pageImages, index) => {
      const pageNumber = index + 1;
      const pageFilename = `${filename} · 第 ${pageNumber}/${imageGroups.length} 页`;
      const pageOcr = ocrResult?.pages?.find(
        (candidate) => candidate.pageNumber === pageNumber,
      );
      const evidenceOptions = { engine: ocrResult?.id || ocrEngine.meta.id };
      const fullOcrEvidence = formatOcrEvidence(pageOcr, { ...evidenceOptions, mode: "full" });
      const coreOcrEvidence = formatOcrEvidence(pageOcr, { ...evidenceOptions, mode: "core" });
      try {
        reportProgress({
          phase: "primary",
          percent: pageProgressPercent(),
          message: `正在主识别第 ${pageNumber}/${imageGroups.length} 页`,
          pageNumber,
          completed: completedPages,
          total: imageGroups.length,
        });
        const primaryPromise = callImageRecognition({
          provider,
          model,
          apiKey,
          imageDataUrls: pageImages,
          filename: pageFilename,
          ocrEvidence: fullOcrEvidence,
          systemPrompt: customContext,
          env,
          fetchImpl,
          signal,
        });

        if (!highAccuracy) {
          const primary = await primaryPromise;
          if (capture) {
            capture.addPageResult(pageNumber, "primary", {
              // OCR evidence has one canonical diagnostic field below; keeping
              // it in request as well would duplicate up to 18 KB per stage.
              request: { systemPrompt: customContext, filename: pageFilename },
              response: primary.response,
              result: primary.result,
              ocrEvidence: fullOcrEvidence,
            });
          }
          completePage(pageNumber);
          return {
            pageNumber,
            responses: [primary.response],
            result: primary.result,
          };
        }

        reportProgress({
          phase: "audit",
          percent: pageProgressPercent(),
          message: `正在独立查漏第 ${pageNumber}/${imageGroups.length} 页`,
          pageNumber,
          completed: completedPages,
          total: imageGroups.length,
        });
        const corePageImages = selectCoreImages(pageImages);
        const auditPromise = callImageRecognition({
          provider,
          model,
          apiKey,
          imageDataUrls: corePageImages,
          imageViewMode: "core",
          filename: `${pageFilename} · 核心字段查漏`,
          schema: CORE_SLATE_SCHEMA,
          systemPrompt: auditContext,
          ocrEvidence: coreOcrEvidence,
          env,
          fetchImpl,
          signal,
        });
        // The primary pass and the independent audit do not depend on each
        // other. Running them together removes one full provider round trip
        // from every high-accuracy page without changing merge semantics.
        const [primary, audit] = await Promise.all([
          primaryPromise,
          auditPromise,
        ]);
        if (capture) {
          capture.addPageResult(pageNumber, "primary", {
            request: { systemPrompt: customContext, filename: pageFilename },
            response: primary.response,
            result: primary.result,
            ocrEvidence: fullOcrEvidence,
          });
          capture.addPageResult(pageNumber, "audit", {
            request: { systemPrompt: auditContext, filename: `${pageFilename} · 核心字段查漏`, viewCount: corePageImages.length },
            response: audit.response,
            result: audit.result,
            ocrEvidence: coreOcrEvidence,
          });
        }
        const combined = mergeHighAccuracyPage(primary.result, audit.result);
        const responses = [primary.response, audit.response];

        if (combined.conflicts.length || combined.auditOnly.length) {
          const reviewTargets = [
            ...combined.conflicts.map(
              ({ key, primaryRecord, auditRecord, fields }) =>
                `${key}（两次识别冲突；冲突字段：${fields.join("、")}；主识别=${formatCoreValues(primaryRecord)}；查漏=${formatCoreValues(auditRecord)}）`,
            ),
            ...combined.auditOnly.map(
              ({ key, auditRecord }) =>
                `${key}（仅核心查漏发现；候选值=${formatCoreValues(auditRecord)}；请先确认图中确实存在此素材）`,
            ),
          ];
          reportProgress({
            phase: "review",
            percent: pageProgressPercent(),
            message: `正在复核第 ${pageNumber} 页的 ${reviewTargets.length} 个冲突或查漏候选`,
            pageNumber,
            completed: completedPages,
            total: imageGroups.length,
          });
          const review = await callImageRecognition({
            provider,
            model,
            apiKey,
            imageDataUrls: corePageImages,
            imageViewMode: "core",
            filename: `${pageFilename} · 冲突复核`,
            schema: CORE_SLATE_SCHEMA,
            systemPrompt: reviewContext,
            userInstruction: `只复核以下 ${reviewTargets.length} 个素材键；图中找不到的键不要输出：\n${reviewTargets.join("\n")}`,
            ocrEvidence: coreOcrEvidence,
            env,
            fetchImpl,
            signal,
          });
          if (capture) {
            capture.addPageResult(pageNumber, "review", {
              request: { systemPrompt: reviewContext, userInstruction: `只复核以下 ${reviewTargets.length} 个素材键`, filename: `${pageFilename} · 冲突复核`, viewCount: corePageImages.length },
              response: review.response,
              result: review.result,
              ocrEvidence: coreOcrEvidence,
            });
          }
          responses.push(review.response);
          applyTargetReview(combined, review.result);
        }

        completePage(pageNumber);
        return {
          pageNumber,
          responses,
          result: combined.result,
        };
      } catch (error) {
        throw pageError(error, pageNumber, imageGroups.length);
      }
    },
  );

  reportProgress({
    phase: "merge",
    percent: 97,
    message: "正在合并逐页结果并检查场、镜、次连续性",
  });
  const result = formatSlateResultFields(
    mergePageResults(pages, accuracyMode),
    effectiveFieldFormats,
  );
  if (ocrDegradedWarning) result.warnings.unshift(ocrDegradedWarning);

  const output = {
    provider: providerId,
    model: responseModelId(provider, model),
    inputMode: "images",
    accuracyMode: highAccuracy ? "high" : "standard",
    durationMs: Date.now() - startedAt,
    pageCount: pages.length,
    usage: aggregateUsage(
      pages.flatMap((page) => page.responses.map((response) => response.usage)),
    ),
    cost: aggregateCost(
      pages.flatMap((page) => page.responses.map((response) => response.cost)),
    ),
    ocr: ocrSummary,
    scenario: publicScenarioSelection(scenarioSelection),
    result,
  };
  if (capture) capture.setFinalResult(output);
  reportProgress({
    phase: "complete",
    percent: 100,
    message: `识别完成，共 ${result.records.length} 条记录`,
    completed: pages.length,
    total: pages.length,
  });
  return output;
}

async function resolveScenarioSelection({
  scenarioStore,
  scenarioId,
  ocrResult,
  filename,
  fieldFormats,
  comments,
}) {
  if (!scenarioStore) return null;
  if (scenarioId) {
    try {
      return {
        profile: await scenarioStore.getProfile(scenarioId),
        match: "selected",
        score: 1,
      };
    } catch (error) {
      const wrapped = clientError(error.message || "场记结构不存在", 400);
      wrapped.cause = error;
      throw wrapped;
    }
  }
  const hasOcrBlocks = (ocrResult?.pages || []).some((page) =>
    (page.views || []).some((view) => Array.isArray(view.blocks) && view.blocks.length),
  );
  if (
    !ocrResult?.used ||
    !Array.isArray(ocrResult.pages) ||
    !ocrResult.pages.length ||
    !hasOcrBlocks
  ) {
    return {
      profile: null,
      match: "fallback",
      score: 0,
      warning: "本次没有可用 OCR 结构证据，未自动匹配场记结构。",
    };
  }
  try {
    const observation = createScenarioObservation(ocrResult, { filename });
    return await scenarioStore.matchAndSave(observation, {
      fieldFormats,
      comments,
    });
  } catch (error) {
    return {
      profile: null,
      match: "fallback",
      score: 0,
      warning: `场记结构学习失败，已继续使用默认规则：${error.message}`,
    };
  }
}

function publicScenarioSelection(selection) {
  if (!selection) return null;
  return {
    id: selection.profile?.id || null,
    match: selection.match || "fallback",
    score: Number(selection.score) || 0,
    fingerprint: selection.profile?.fingerprint || null,
    warning: selection.warning || null,
  };
}

function createProgressReporter(callback) {
  let lastPercent = 0;
  return (event) => {
    if (typeof callback !== "function") return;
    const requestedPercent = Number(event?.percent);
    const percent = Number.isFinite(requestedPercent)
      ? Math.max(lastPercent, Math.min(100, Math.max(0, Math.round(requestedPercent))))
      : lastPercent;
    lastPercent = percent;
    const progress = {
      type: "progress",
      ...event,
      percent,
    };
    try {
      const pending = callback(progress);
      if (pending && typeof pending.catch === "function") pending.catch(() => {});
    } catch {
      // UI progress is advisory; a disconnected observer must not abort recognition.
    }
  };
}

async function callImageRecognition({
  provider,
  model,
  apiKey,
  imageDataUrls,
  imageViewMode,
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  ocrEvidence,
  env,
  fetchImpl,
  signal,
}) {
  const combinedInstruction = [userInstruction, ocrEvidence]
    .filter(Boolean)
    .join("\n\n");
  const response =
    provider.transport === "responses"
      ? await callOpenAI({
          provider,
          model,
          apiKey,
          imageDataUrls,
          imageViewMode,
          filename,
          schema,
          systemPrompt,
          userInstruction: combinedInstruction,
          env,
          fetchImpl,
          signal,
        })
      : await callChatCompletions({
          provider,
          model,
          apiKey,
          imageDataUrls,
          imageViewMode,
          filename,
          schema,
          systemPrompt,
          userInstruction: combinedInstruction,
          env,
          fetchImpl,
          signal,
        });
  return {
    response,
    result: normalizeSlateResult(parseJsonResponse(response.text)),
  };
}

function mergeHighAccuracyPage(primary, audit) {
  const records = [];
  const byMaterial = new Map();
  const warnings = [
    ...primary.warnings.map((warning) => `主识别：${warning}`),
    ...audit.warnings.map((warning) => `核心查漏：${warning}`),
  ];

  for (const record of primary.records) {
    const key = materialKey(record);
    if (!key) {
      records.push(record);
      warnings.push("主识别返回了一条缺少有效卷号或视频码的记录，请人工核对。");
      continue;
    }
    if (byMaterial.has(key)) {
      warnings.push(`主识别重复返回 ${key}，已保留第一条。`);
      continue;
    }
    records.push(record);
    byMaterial.set(key, record);
  }

  const conflicts = [];
  const auditOnly = [];
  for (const auditRecord of audit.records) {
    const key = materialKey(auditRecord);
    if (!key) {
      warnings.push("核心查漏返回了一条缺少有效卷号或视频码的记录，未自动合并。");
      continue;
    }
    const primaryRecord = byMaterial.get(key);
    if (!primaryRecord) {
      const recovered = { ...auditRecord };
      records.push(recovered);
      byMaterial.set(key, recovered);
      auditOnly.push({ key, record: recovered, auditRecord });
      warnings.push(`${key} 仅由核心查漏识别到，已暂列查漏候选并等待最终定向确认。`);
      lowerConfidence(recovered);
      continue;
    }

    const fields = [];
    for (const field of ["scene", "shot", "take", "takeStatus"]) {
      const primaryValue = primaryRecord[field];
      const auditValue = auditRecord[field];
      if (!primaryValue && auditValue) {
        primaryRecord[field] = auditValue;
        lowerConfidence(primaryRecord);
      } else if (primaryValue && auditValue && primaryValue !== auditValue) {
        fields.push(field);
      }
    }
    if (fields.length) {
      conflicts.push({ key, record: primaryRecord, primaryRecord, auditRecord, fields });
    }
  }

  records.sort(compareMaterialRecords);
  return {
    result: {
      sheetTitle: primary.sheetTitle || audit.sheetTitle,
      records,
      warnings,
    },
    conflicts,
    auditOnly,
  };
}

function applyTargetReview(combined, review) {
  const reviewedByMaterial = new Map(
    review.records
      .map((record) => [materialKey(record), record])
      .filter(([key]) => key),
  );
  combined.result.warnings.push(
    ...review.warnings.map((warning) => `冲突复核：${warning}`),
  );

  for (const conflict of combined.conflicts) {
    const reviewed = reviewedByMaterial.get(conflict.key);
    const unresolved = [];
    for (const field of conflict.fields) {
      if (reviewed?.[field]) {
        conflict.record[field] = reviewed[field];
      } else {
        conflict.record[field] = null;
        unresolved.push(field);
      }
    }
    lowerConfidence(conflict.record);
    if (unresolved.length) {
      conflict.record.reviewRequiredFields = [
        ...new Set([
          ...(conflict.record.reviewRequiredFields || []),
          ...unresolved,
        ]),
      ];
      combined.result.warnings.push(
        `${conflict.key} 的${fieldLabels(unresolved)}在两次识别中冲突，最终复核仍无法确认，已留空，请人工核对。`,
      );
    } else {
      combined.result.warnings.push(
        `${conflict.key} 的${fieldLabels(conflict.fields)}存在识别冲突，已采用第三次定向复核结果。`,
      );
    }
  }

  for (const candidate of combined.auditOnly) {
    const reviewed = reviewedByMaterial.get(candidate.key);
    if (!reviewed) {
      const index = combined.result.records.indexOf(candidate.record);
      if (index >= 0) combined.result.records.splice(index, 1);
      combined.result.warnings.push(
        `${candidate.key} 仅在核心查漏中出现，但最终定向复核未确认，已从结果移除。`,
      );
      continue;
    }

    for (const field of ["scene", "shot", "take", "takeStatus"]) {
      if (reviewed[field]) candidate.record[field] = reviewed[field];
    }
    lowerConfidence(candidate.record);
    combined.result.warnings.push(
      `${candidate.key} 已由最终定向复核确认存在，保留为查漏补回记录，请人工复核场/镜/次。`,
    );
  }
}

function materialKey(record) {
  const reel = normalizeReel(record?.cardNumber);
  const clip = videoCodeOrdinal(record?.videoCode);
  if (!reel || clip == null) return null;
  return `${reel}C${String(clip).padStart(3, "0")}`;
}

function compareMaterialRecords(left, right) {
  const leftKey = materialKey(left);
  const rightKey = materialKey(right);
  if (!leftKey && !rightKey) return 0;
  if (!leftKey) return 1;
  if (!rightKey) return -1;
  const reelOrder = normalizeReel(left.cardNumber).localeCompare(
    normalizeReel(right.cardNumber),
  );
  return reelOrder || videoCodeOrdinal(left.videoCode) - videoCodeOrdinal(right.videoCode);
}

function formatCoreValues(record) {
  return `场${record.scene || "空"}/镜${record.shot || "空"}/次${record.take || "空"}/状态${record.takeStatus || "空"}`;
}

function fieldLabels(fields) {
  const labels = { scene: "场次", shot: "镜", take: "次", takeStatus: "状态" };
  return fields.map((field) => labels[field] || field).join("、");
}

function mergePageResults(pages, accuracyMode) {
  const records = [];
  const warnings = [];
  let sheetTitle = null;

  for (const page of pages) {
    sheetTitle ||= page.result.sheetTitle;
    if (!page.result.records.length) {
      warnings.push(`第 ${page.pageNumber} 页未识别到任何视频码。`);
    }
    for (const [index, record] of page.result.records.entries()) {
      records.push({
        ...record,
        id: `record-page-${page.pageNumber}-${index}`,
        sourcePage: page.pageNumber,
      });
    }
    warnings.push(
      ...page.result.warnings.map(
        (warning) => `第 ${page.pageNumber} 页：${warning}`,
      ),
    );
  }

  inheritSceneAndShot(records, warnings);
  reconcileRecordSequences(records, warnings);
  validateRecordSequences(records, warnings, accuracyMode);
  return { sheetTitle, records, warnings };
}

function inheritSceneAndShot(records, warnings) {
  const lastByReel = new Map();
  const orderedRecords = records
    .map((record, index) => ({
      record,
      index,
      reel: normalizeReel(record.cardNumber),
      page: Number(record.sourcePage) || 0,
      clip: videoCodeOrdinal(record.videoCode),
    }))
    .filter((item) => item.reel)
    .sort(
      (left, right) =>
        left.page - right.page ||
        left.reel.localeCompare(right.reel) ||
        compareOptionalNumber(left.clip, right.clip) ||
        left.index - right.index,
    );

  for (const { record, reel } of orderedRecords) {
    const previous = lastByReel.get(reel);
    const inherited = [];
    const explicitScene = record.scene;

    if (!record.scene && previous?.scene && !requiresManualReview(record, "scene")) {
      record.scene = previous.scene;
      inherited.push("场次");
    }
    if (
      !record.shot &&
      previous?.shot &&
      !requiresManualReview(record, "shot") &&
      (!explicitScene || explicitScene === previous.scene)
    ) {
      record.shot = previous.shot;
      inherited.push("镜");
    }

    if (inherited.length) {
      warnings.push(
        `第 ${record.sourcePage} 页 ${reel} ${record.videoCode || "未知条号"} 的${inherited.join("、")}已按同卷条号顺序的上一条记录继承。`,
      );
    }

    lastByReel.set(reel, {
      scene: record.scene || null,
      shot: record.shot || null,
    });
  }
}

function reconcileRecordSequences(records, warnings) {
  const byReel = new Map();
  records.forEach((record, index) => {
    const reel = normalizeReel(record.cardNumber);
    const clip = videoCodeOrdinal(record.videoCode);
    if (!reel || clip == null) return;
    const group = byReel.get(reel) || [];
    group.push({ record, index, clip });
    byReel.set(reel, group);
  });

  for (const [reel, group] of byReel) {
    group.sort((left, right) => left.clip - right.clip || left.index - right.index);
    repairSandwichedRows(group, reel, warnings);
    repairDroppedShotTens(group, reel, warnings);
  }
}

// Warning-only continuity checks: delegates to the shared detector in
// public/resolve-csv.js so the result warnings and the merge-preview red
// flags can never drift apart. Nothing is auto-corrected here.
function validateRecordSequences(records, warnings, accuracyMode) {
  const anomalies = detectSlateSequenceAnomalies(records);
  for (const anomaly of anomalies) {
    const parsed = parseCanonicalMaterialKey(anomaly.key);
    const reel = parsed
      ? `${parsed.camera}${String(parsed.reel).padStart(3, "0")}`
      : anomaly.key;
    warnings.push(`${reel} ${anomaly.message}，请人工核对。`);
  }
  if (anomalies.length && accuracyMode !== "high") {
    warnings.push(
      `快速模式仅执行单次识别，以上 ${anomalies.length} 条序列异常未经过双重校验，建议使用精确模式重新识别。`,
    );
  }
}

function repairSandwichedRows(group, reel, warnings) {
  for (let index = 1; index < group.length - 1; index += 1) {
    const previous = group[index - 1];
    const current = group[index];
    const next = group[index + 1];
    if (
      current.clip !== previous.clip + 1 ||
      next.clip !== current.clip + 1 ||
      !sameScene(previous.record, current.record, next.record) ||
      !previous.record.shot ||
      previous.record.shot !== next.record.shot ||
      requiresManualReview(current.record, "shot") ||
      requiresManualReview(current.record, "take")
    ) {
      continue;
    }

    const previousTake = normalizedNumber(previous.record.take);
    const nextTake = normalizedNumber(next.record.take);
    if (previousTake == null || nextTake !== previousTake + 2) continue;

    const expectedTake = String(previousTake + 1).padStart(2, "0");
    const expectedShot = previous.record.shot;
    if (
      current.record.shot === expectedShot &&
      current.record.take === expectedTake
    ) {
      continue;
    }

    const oldValue = `${current.record.shot || "空"}/${current.record.take || "空"}`;
    current.record.shot = expectedShot;
    current.record.take = expectedTake;
    lowerConfidence(current.record);
    warnings.push(
      `第 ${current.record.sourcePage || "?"} 页 ${reel} ${current.record.videoCode || "未知条号"} 位于连续条号与同镜次序之间，已将镜/次从 ${oldValue} 校正为 ${expectedShot}/${expectedTake}，请人工复核。`,
    );
  }
}

function repairDroppedShotTens(group, reel, warnings) {
  for (let index = 1; index < group.length; index += 1) {
    const previous = group[index - 1];
    const current = group[index];
    if (
      current.clip !== previous.clip + 1 ||
      !sameScene(previous.record, current.record) ||
      normalizedNumber(current.record.take) !== 1 ||
      requiresManualReview(current.record, "shot") ||
      requiresManualReview(current.record, "take")
    ) {
      continue;
    }

    const previousShot = normalizedNumber(previous.record.shot);
    const currentShot = normalizedNumber(current.record.shot);
    const expectedShot = previousShot == null ? null : previousShot + 1;
    if (
      previousShot == null ||
      currentShot == null ||
      currentShot >= 10 ||
      expectedShot < 10 ||
      expectedShot >= 100 ||
      expectedShot % 10 !== currentShot
    ) {
      continue;
    }

    const run = [current];
    let expectedTake = 2;
    for (let cursor = index + 1; cursor < group.length; cursor += 1) {
      const candidate = group[cursor];
      const preceding = group[cursor - 1];
      if (
        candidate.clip !== preceding.clip + 1 ||
        !sameScene(current.record, candidate.record) ||
        requiresManualReview(candidate.record, "shot") ||
        requiresManualReview(candidate.record, "take") ||
        normalizedNumber(candidate.record.shot) !== currentShot ||
        normalizedNumber(candidate.record.take) !== expectedTake
      ) {
        break;
      }
      run.push(candidate);
      expectedTake += 1;
    }
    if (run.length < 2) continue;

    const correctedShot = String(expectedShot).padStart(2, "0");
    const recognizedShot = current.record.shot;
    for (const item of run) {
      item.record.shot = correctedShot;
      lowerConfidence(item.record);
    }
    warnings.push(
      `第 ${current.record.sourcePage || "?"} 页 ${reel} ${run[0].record.videoCode}–${run.at(-1).record.videoCode} 的镜号连续从 ${previous.record.shot} 进入下一组，已将疑似漏写十位的 ${recognizedShot} 校正为 ${correctedShot}，请人工复核。`,
    );
    index += run.length - 1;
  }
}

function sameScene(...records) {
  const scenes = records.map((record) => record.scene).filter(Boolean);
  return scenes.length === records.length && scenes.every((scene) => scene === scenes[0]);
}

function normalizedNumber(value) {
  if (!/^\d+$/.test(String(value || ""))) return null;
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : null;
}

function lowerConfidence(record) {
  if (record.confidence === "high") record.confidence = "medium";
}

function requiresManualReview(record, field) {
  return Array.isArray(record?.reviewRequiredFields) &&
    record.reviewRequiredFields.includes(field);
}

function videoCodeOrdinal(value) {
  const match = String(value || "").toUpperCase().match(/^C?0*(\d+)$/);
  return match ? Number(match[1]) : null;
}

function compareOptionalNumber(left, right) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  return left - right;
}

function aggregateUsage(usages) {
  const total = {};
  for (const usage of usages) {
    if (!usage || typeof usage !== "object") continue;
    for (const [key, value] of Object.entries(usage)) {
      if (typeof value === "number" && Number.isFinite(value)) {
        total[key] = (total[key] || 0) + value;
      }
    }
  }
  return Object.keys(total).length ? total : null;
}

function aggregateCost(costs) {
  const numbers = costs.filter(
    (cost) => typeof cost === "number" && Number.isFinite(cost),
  );
  return numbers.length ? numbers.reduce((sum, cost) => sum + cost, 0) : null;
}

async function mapWithConcurrency(items, limit, mapper) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await mapper(items[index], index);
    }
  }

  const workerCount = Math.min(Math.max(1, limit), items.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
  return results;
}

function normalizeReel(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function pageError(error, pageNumber, pageCount) {
  if (error?.code === "RECOGNITION_CANCELED") return error;
  const wrapped = new Error(
    `第 ${pageNumber}/${pageCount} 页识别失败：${error?.message || "未知错误"}`,
  );
  wrapped.status = error?.status || 502;
  wrapped.providerError = error?.providerError ?? true;
  return wrapped;
}

async function callOpenAI({
  provider,
  model,
  apiKey,
  imageDataUrls,
  imageViewMode,
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  env,
  fetchImpl,
  signal,
}) {
  const payload = {
    model: model.apiId,
    store: false,
    max_output_tokens: 16000,
    input: [
      {
        role: "system",
        content: systemPrompt,
      },
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: buildUserText({
              imageDataUrls,
              imageViewMode,
              filename,
              userInstruction,
            }),
          },
          ...imageDataUrls.map((imageDataUrl) => ({
            type: "input_image",
            image_url: imageDataUrl,
            detail: model.imageDetail || "auto",
          })),
        ],
      },
    ],
    text: {
      format: {
        type: "json_schema",
        name: "slate_sheet",
        description: "场记单结构化识别结果",
        strict: true,
        schema,
      },
    },
  };

  const data = await postJson(
    `${provider.baseUrl}/responses`,
    payload,
    {
      Authorization: `Bearer ${apiKey}`,
    },
    fetchImpl,
    provider.timeoutMs,
    provider.maxRetries,
    signal,
  );

  return {
    text: extractResponsesText(data),
    usage: data.usage || null,
    cost: data.usage?.cost ?? null,
  };
}

async function callChatCompletions({
  provider,
  model,
  apiKey,
  imageDataUrls,
  imageViewMode,
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  env,
  fetchImpl,
  signal,
}) {
  const headers = {
    Authorization: `Bearer ${apiKey}`,
  };
  if (provider.id === "openrouter") {
    headers["X-Title"] = "SlateSync";
  }
  if (provider.id === "openrouter" && env.OPENROUTER_SITE_URL) {
    headers["HTTP-Referer"] = env.OPENROUTER_SITE_URL;
  }

  let jsonMode = chatJsonMode(provider, model);
  let data;
  while (!data) {
    try {
      data = await postChatCompletions(
        provider,
        buildChatCompletionsPayload({
          provider,
          model,
          imageDataUrls,
          imageViewMode,
          filename,
          schema,
          systemPrompt,
          userInstruction,
          jsonMode,
        }),
        headers,
        fetchImpl,
        provider.timeoutMs,
        signal,
      );
    } catch (error) {
      const fallbackJsonMode = nextChatJsonMode(jsonMode, error);
      if (!fallbackJsonMode) throw error;
      jsonMode = fallbackJsonMode;
    }
  }

  const choice = data.choices?.[0];
  return {
    text: extractChatText(choice?.message?.content),
    usage: data.usage || null,
    cost: data.usage?.cost ?? data.cost ?? null,
  };
}

function buildChatCompletionsPayload({
  provider,
  model,
  imageDataUrls,
  imageViewMode,
  filename,
  jsonMode,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
}) {
  const effectiveSystemPrompt = jsonMode === "json_schema"
    ? systemPrompt
    : `${systemPrompt}\n\n当前模型端点不支持原生 JSON Schema。请只返回一个 JSON 对象，不要输出 Markdown、解释或代码块，并严格遵守以下 Schema：\n${JSON.stringify(schema)}`;

  const payload = {
    model: model.apiId,
    stream: false,
    max_tokens: 16000,
    messages: [
      {
        role: "system",
        content: effectiveSystemPrompt,
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: buildUserText({
              imageDataUrls,
              imageViewMode,
              filename,
              userInstruction,
            }),
          },
          ...imageDataUrls.map((imageDataUrl) => ({
            type: "image_url",
            image_url: {
              url: imageDataUrl,
            },
          })),
        ],
      },
    ],
  };

  if (jsonMode === "json_schema") {
    payload.response_format = {
      type: "json_schema",
      json_schema: {
        name: "slate_sheet",
        description: "场记单结构化识别结果",
        strict: true,
        schema,
      },
    };
  } else if (jsonMode === "json_object") {
    payload.response_format = { type: "json_object" };
  }
  if (provider.id === "openrouter") {
    payload.provider = {
      require_parameters: true,
    };
  }
  return payload;
}

function buildUserText({
  imageDataUrls = [],
  imageViewMode,
  filename,
  userInstruction,
}) {
  const base = imageViewMode === "core"
      ? `以下 ${imageDataUrls.length} 张图是同一个来源页的核心字段局部放大视图，必须合并为一页识别，不能重复输出记录。来源：${filename}`
      : imageDataUrls.length > 1
      ? `以下 ${imageDataUrls.length} 张图是同一个来源页的整页图与局部放大图，必须合并为一页识别，不能重复输出记录。来源：${filename}`
      : `识别这一页场记单。来源：${filename}`;
  return userInstruction ? `${base}\n\n${userInstruction}` : base;
}

function selectCoreImages(pageImages) {
  return pageImages.length > 1 ? pageImages.slice(1) : pageImages;
}

function pageConcurrency(env) {
  const value = Number(env.MODEL_PAGE_CONCURRENCY);
  return Number.isInteger(value) && value >= 1 && value <= 6
    ? value
    : DEFAULT_PAGE_CONCURRENCY;
}

async function postChatCompletions(provider, payload, headers, fetchImpl, timeoutMs, signal) {
  const data = await postJson(
    `${provider.baseUrl}/chat/completions`,
    payload,
    headers,
    fetchImpl,
    timeoutMs,
    provider.maxRetries,
    signal,
  );
  const choice = data.choices?.[0];
  if (choice?.error) {
    throw providerError(
      choice.error.message || `${provider.label} 模型调用失败`,
      502,
    );
  }
  return data;
}

function isNoCompatibleEndpoint(error) {
  return /no endpoints found that can handle the requested parameters/i.test(
    error?.message || "",
  );
}

function chatJsonMode(provider, model) {
  if (provider.id === "openrouter") {
    return model.openRouterStructuredOutputs === false
      ? "json_object"
      : "json_schema";
  }
  return provider.chatJsonMode || "json_object";
}

function nextChatJsonMode(currentMode, error) {
  if (currentMode === "json_schema" && (
    isNoCompatibleEndpoint(error) || isResponseFormatUnsupported(error)
  )) {
    return "json_object";
  }
  if (currentMode === "json_object" && isResponseFormatUnsupported(error)) {
    return "prompt";
  }
  return null;
}

function isResponseFormatUnsupported(error) {
  return (
    [400, 404, 422].includes(Number(error?.status)) &&
    /response[_ -]?format|json[_ -]?schema|json[_ -]?object|structured output|unsupported.*(?:schema|json)/i.test(
      error?.message || "",
    )
  );
}

async function postJson(
  url,
  payload,
  headers,
  fetchImpl,
  timeoutMs,
  maxRetries = DEFAULT_REQUEST_MAX_RETRIES,
  signal = null,
) {
  const effectiveTimeout = timeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
  const attempts = Math.max(1, maxRetries + 1);
  let response;

  // A model request is safe to retry after its client-side timeout: every
  // attempt is stateless and the final recognition result is persisted once.
  // Electron/undici versions surface AbortSignal.timeout() as either
  // TimeoutError or AbortError, so normalize both forms here.
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    throwIfRecognitionCanceled(signal);
    const startedAt = Date.now();
    try {
      const timeoutSignal = AbortSignal.timeout(effectiveTimeout);
      response = await fetchImpl(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...headers,
        },
        body: JSON.stringify(payload),
        signal: signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal,
      });
      break;
    } catch (error) {
      if (signal?.aborted) throw recognitionCanceledError();
      if (isRequestTimeout(error)) {
        if (attempt < attempts) {
          console.warn(
            `[model-request] 请求超时，正在重试（${attempt}/${maxRetries}）：${url}`,
          );
          continue;
        }
        const attemptNote = attempts > 1
          ? `，共尝试 ${attempts} 次`
          : "";
        throw providerError(
          `模型请求超时（单次等待上限 ${Math.round(effectiveTimeout / 1000)} 秒${attemptNote}），请稍后重试`,
          504,
        );
      }
      const detail = fetchErrorDetail(error);
      console.error(
        `[model-request] 连接模型服务失败：${url}（${Math.round((Date.now() - startedAt) / 1000)}s）→ ${detail}`,
      );
      throw providerError(`无法连接模型服务：${detail}`, 502);
    }
  }

  let raw;
  try {
    raw = await response.text();
  } catch (error) {
    if (signal?.aborted) throw recognitionCanceledError();
    throw error;
  }
  let data;
  try {
    data = raw ? JSON.parse(raw) : {};
  } catch {
    throw providerError(`模型服务返回了无法解析的响应（HTTP ${response.status}）`, 502);
  }

  if (!response.ok || data.error) {
    const message =
      data.error?.message ||
      data.message ||
      `模型服务请求失败（HTTP ${response.status}）`;
    throw providerError(message, response.status || 502);
  }

  return data;
}

function extractResponsesText(data) {
  if (typeof data.output_text === "string" && data.output_text) {
    return data.output_text;
  }

  const parts = [];
  for (const output of data.output || []) {
    for (const content of output.content || []) {
      if (content.type === "output_text" && typeof content.text === "string") {
        parts.push(content.text);
      }
    }
  }
  if (!parts.length) {
    throw providerError("OpenAI 响应中没有可用的文本结果", 502);
  }
  return parts.join("");
}

function extractChatText(content) {
  if (typeof content === "string" && content) {
    return content;
  }
  if (Array.isArray(content)) {
    const text = content
      .filter((part) => part?.type === "text" && typeof part.text === "string")
      .map((part) => part.text)
      .join("");
    if (text) return text;
  }
  throw providerError("Chat Completions 响应中没有可用的文本结果", 502);
}

function parseJsonResponse(text) {
  const cleaned = text
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  try {
    return JSON.parse(cleaned);
  } catch {
    throw providerError("模型没有返回有效的结构化 JSON", 502);
  }
}

function isSupportedImageDataUrl(value) {
  return (
    typeof value === "string" &&
    /^data:image\/(?:jpeg|png|webp);base64,[A-Za-z0-9+/=\s]+$/.test(value)
  );
}

export function resolveOcrEngine(env, options = {}) {
  if (options.ocrImpl) {
    return {
      impl: options.ocrImpl,
      meta: options.ocrMeta || { id: "custom", label: "本地 OCR" },
    };
  }
  const autoEnable = options.ocrAutoEnable ?? env === process.env;
  const selection = resolveOcrSelection(env, { autoEnable });
  if (selection.id === "vision") {
    return { impl: runVisionOcrForPages, meta: selection.engine };
  }
  // Keep the optional no-op fallback on PaddleOCR when neither engine is
  // enabled; its runner returns the canonical image-only degradation result.
  return { impl: runPaddleOcrForPages, meta: selection.engine };
}

function stripTrailingSlash(value) {
  return value.replace(/\/+$/, "");
}

function normalizeBaseUrl(value, envName) {
  const normalized = String(value || "").trim();
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    throw clientError(`${envName} 必须是有效的 http(s) URL`, 400);
  }
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw clientError(`${envName} 只支持 http:// 或 https://`, 400);
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw clientError(`${envName} 不能包含账号、密码、查询参数或片段`, 400);
  }
  return stripTrailingSlash(parsed.toString());
}

// 单个模型请求的超时：默认 180 秒；可用 MODEL_REQUEST_TIMEOUT_MS 调整（30 秒–60 分钟）
function modelRequestTimeoutMs(env) {
  const raw = Number(String(env?.MODEL_REQUEST_TIMEOUT_MS || "").trim());
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_REQUEST_TIMEOUT_MS;
  return Math.min(3_600_000, Math.max(30_000, Math.round(raw)));
}

// 超时后自动重试次数：默认 1 次；可用 MODEL_REQUEST_MAX_RETRIES 调整（0–3 次）
function modelRequestMaxRetries(env) {
  const configured = String(env?.MODEL_REQUEST_MAX_RETRIES ?? "").trim();
  if (!configured) return DEFAULT_REQUEST_MAX_RETRIES;
  const raw = Number(configured);
  if (!Number.isInteger(raw) || raw < 0) return DEFAULT_REQUEST_MAX_RETRIES;
  return Math.min(3, raw);
}

function isRequestTimeout(error) {
  const details = [
    error?.name,
    error?.message,
    error?.cause?.name,
    error?.cause?.message,
  ].filter(Boolean).join(" ");
  return error?.name === "TimeoutError" || (
    error?.name === "AbortError" && /timeout|timed out/i.test(details)
  );
}

function fetchErrorDetail(error) {
  const causes = error?.cause?.errors || (error?.cause ? [error.cause] : []);
  const details = causes.map((cause) =>
    String(cause?.message || cause).slice(0, 300),
  );
  return details.length ? details.join("；") : String(error?.message || error);
}

function responseModelId(provider, model) {
  return provider.id === "openai-compatible" ? model.apiId : model.id;
}

function clientError(message, status) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function providerError(message, status) {
  const error = new Error(message);
  error.status = status;
  error.providerError = true;
  return error;
}

export { MODELS };
