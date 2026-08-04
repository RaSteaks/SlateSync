import { MODELS, resolveModel, resolveProvider } from "./config.mjs";
import {
  formatOcrEvidence,
  paddleOcrPublicConfig,
  runPaddleOcrForPages,
  summarizeOcrResult,
} from "./ocr/paddleocr.mjs";
import {
  CORE_AUDIT_SYSTEM_PROMPT,
  CORE_REVIEW_SYSTEM_PROMPT,
  CORE_SLATE_SCHEMA,
  formatSlateResultFields,
  normalizeSlateResult,
  PDF_SLATE_SCHEMA,
  PDF_SYSTEM_PROMPT,
  SLATE_SCHEMA,
  SYSTEM_PROMPT,
} from "./schema.mjs";

const REQUEST_TIMEOUT_MS = 180_000;
const PAGE_CONCURRENCY = 2;

export async function recognizeSlate(
  {
    providerId,
    modelId,
    imageDataUrl,
    imageDataUrls,
    imageDataGroups,
    pdfDataUrl,
    pageCount,
    filename = "slate",
    accuracyMode = "standard",
    fieldFormats,
  },
  options = {},
) {
  const env = options.env || process.env;
  const fetchImpl = options.fetchImpl || fetch;
  const reportProgress = createProgressReporter(options.onProgress);
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
  const hasPdf = isSupportedPdfDataUrl(pdfDataUrl);
  if (pdfDataUrl && !hasPdf) {
    throw clientError("PDF 数据格式无效", 400);
  }
  if (hasPdf && (images.length || imageGroups.length)) {
    throw clientError("PDF 与页面图片不能同时提交", 400);
  }
  if (!hasPdf && (
    imageGroups.length < 1 ||
    imageGroups.length > 20 ||
    !imageGroups.every(
      (group) =>
        Array.isArray(group) &&
        group.length >= 1 &&
        group.length <= 3 &&
        group.every(isSupportedImageDataUrl),
    )
  )) {
    throw clientError("只支持 1–20 页图片，每页可包含 1–3 张 JPEG、PNG 或 WebP 视图", 400);
  }
  const normalizedPageCount = hasPdf ? normalizePageCount(pageCount) : imageGroups.length;
  if (hasPdf && !normalizedPageCount) {
    throw clientError("PDF 页数必须是 1–20", 400);
  }

  const apiKey = String(env[provider.envKey]).trim();

  const startedAt = Date.now();
  reportProgress({
    phase: "starting",
    percent: 2,
    message: `正在准备 ${normalizedPageCount} 页识别任务`,
    completed: 0,
    total: normalizedPageCount,
  });
  const ocrImpl = options.ocrImpl || runPaddleOcrForPages;
  reportProgress({
    phase: "ocr",
    percent: 5,
    message: hasPdf ? "正在准备 PDF 模型输入" : "正在启动 PaddleOCR 文字与坐标提取",
  });
  const ocrResult = hasPdf
    ? skippedDirectPdfOcr(env)
    : await ocrImpl(imageGroups, {
        env,
        autoEnable: options.ocrAutoEnable ?? env === process.env,
        onProgress: (progress) => {
          const completed = Math.max(0, Number(progress?.completedViews) || 0);
          const total = Math.max(0, Number(progress?.totalViews) || 0);
          const ratio = total ? Math.min(1, completed / total) : 0;
          reportProgress({
            phase: "ocr",
            percent: Math.round(5 + ratio * 30),
            message: progress?.cacheHit
              ? "已复用本地 PaddleOCR 结果"
              : completed
                ? `PaddleOCR 已处理 ${completed}/${total} 个页面视图`
                : "PaddleOCR 模型已就绪，开始逐视图识别",
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
  const ocrSummary = summarizeOcrResult(ocrResult);
  reportProgress({
    phase: "ocr",
    percent: 35,
    message: ocrSummary.used
      ? `PaddleOCR 完成：提取 ${ocrSummary.blockCount} 个文字块`
      : ocrSummary.warning
        ? "PaddleOCR 已降级，继续使用多模态模型"
        : "未启用 PaddleOCR，继续使用多模态模型",
  });
  if (hasPdf) {
    let response;
    let normalized;
    try {
      reportProgress({
        phase: "primary",
        percent: 40,
        message: `多模态模型正在读取完整 PDF（${normalizedPageCount} 页）`,
      });
      response =
        provider.transport === "responses"
          ? await callOpenAI({
              provider,
              model,
              apiKey,
              pdfDataUrl,
              pageCount: normalizedPageCount,
              filename,
              schema: PDF_SLATE_SCHEMA,
              systemPrompt: PDF_SYSTEM_PROMPT,
              env,
              fetchImpl,
            })
          : await callChatCompletions({
              provider,
              model,
              apiKey,
              pdfDataUrl,
              pageCount: normalizedPageCount,
              filename,
              schema: PDF_SLATE_SCHEMA,
              systemPrompt: PDF_SYSTEM_PROMPT,
              env,
              fetchImpl,
            });
      normalized = normalizeSlateResult(parseJsonResponse(response.text));
    } catch (error) {
      throw pdfError(error, normalizedPageCount);
    }

    reportProgress({
      phase: "merge",
      percent: 96,
      message: "正在合并 PDF 页面记录并检查字段连续性",
    });
    const result = formatSlateResultFields(
      mergePdfResult(normalized, normalizedPageCount),
      fieldFormats,
    );
    if (ocrSummary.warning) result.warnings.unshift(ocrSummary.warning);

    const output = {
      provider: providerId,
      model: responseModelId(provider, model),
      inputMode: "pdf",
      durationMs: Date.now() - startedAt,
      pageCount: normalizedPageCount,
      accuracyMode: "standard",
      usage: response.usage || null,
      cost: response.cost ?? null,
      ocr: ocrSummary,
      result,
    };
    reportProgress({
      phase: "complete",
      percent: 100,
      message: `识别完成，共 ${result.records.length} 条记录`,
      completed: normalizedPageCount,
      total: normalizedPageCount,
    });
    return output;
  }

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
    PAGE_CONCURRENCY,
    async (pageImages, index) => {
      const pageNumber = index + 1;
      const pageFilename = `${filename} · 第 ${pageNumber}/${imageGroups.length} 页`;
      const pageOcr = ocrResult.pages?.find(
        (candidate) => candidate.pageNumber === pageNumber,
      );
      const fullOcrEvidence = formatOcrEvidence(pageOcr, { mode: "full" });
      const coreOcrEvidence = formatOcrEvidence(pageOcr, { mode: "core" });
      try {
        reportProgress({
          phase: "primary",
          percent: pageProgressPercent(),
          message: `正在主识别第 ${pageNumber}/${imageGroups.length} 页`,
          pageNumber,
          completed: completedPages,
          total: imageGroups.length,
        });
        const primary = await callImageRecognition({
          provider,
          model,
          apiKey,
          imageDataUrls: pageImages,
          filename: pageFilename,
          ocrEvidence: fullOcrEvidence,
          env,
          fetchImpl,
        });

        if (!highAccuracy) {
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
        const audit = await callImageRecognition({
          provider,
          model,
          apiKey,
          imageDataUrls: pageImages,
          filename: `${pageFilename} · 核心字段查漏`,
          schema: CORE_SLATE_SCHEMA,
          systemPrompt: CORE_AUDIT_SYSTEM_PROMPT,
          ocrEvidence: coreOcrEvidence,
          env,
          fetchImpl,
        });
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
            imageDataUrls: pageImages,
            filename: `${pageFilename} · 冲突复核`,
            schema: CORE_SLATE_SCHEMA,
            systemPrompt: CORE_REVIEW_SYSTEM_PROMPT,
            userInstruction: `只复核以下 ${reviewTargets.length} 个素材键；图中找不到的键不要输出：\n${reviewTargets.join("\n")}`,
            ocrEvidence: coreOcrEvidence,
            env,
            fetchImpl,
          });
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
    mergePageResults(pages),
    fieldFormats,
  );
  if (ocrSummary.warning) {
    result.warnings.unshift(ocrSummary.warning);
  } else if (ocrSummary.used && ocrSummary.blockCount === 0) {
    result.warnings.unshift(
      "PaddleOCR 已运行但未检测到文字，当前结果主要依赖多模态图像识别。",
    );
  }

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
    result,
  };
  reportProgress({
    phase: "complete",
    percent: 100,
    message: `识别完成，共 ${result.records.length} 条记录`,
    completed: pages.length,
    total: pages.length,
  });
  return output;
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
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  ocrEvidence,
  env,
  fetchImpl,
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
          filename,
          schema,
          systemPrompt,
          userInstruction: combinedInstruction,
          env,
          fetchImpl,
        })
      : await callChatCompletions({
          provider,
          model,
          apiKey,
          imageDataUrls,
          filename,
          schema,
          systemPrompt,
          userInstruction: combinedInstruction,
          env,
          fetchImpl,
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

function mergePdfResult(result, pageCount) {
  const warnings = [...result.warnings];
  const records = result.records.map((record, index) => {
    const sourcePage = normalizePageCount(record.sourcePage);
    if (!sourcePage || sourcePage > pageCount) {
      warnings.push(
        `${record.cardNumber || "未知卷号"} ${record.videoCode || "未知条号"} 未返回有效 PDF 页码，请人工核对。`,
      );
    }
    return {
      ...record,
      id: `record-pdf-${sourcePage || 0}-${index}`,
      sourcePage: sourcePage && sourcePage <= pageCount ? sourcePage : null,
    };
  });
  inheritSceneAndShot(records, warnings);
  reconcileRecordSequences(records, warnings);
  return { sheetTitle: result.sheetTitle, records, warnings };
}

function mergePageResults(pages) {
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
  const wrapped = new Error(
    `第 ${pageNumber}/${pageCount} 页识别失败：${error?.message || "未知错误"}`,
  );
  wrapped.status = error?.status || 502;
  wrapped.providerError = error?.providerError ?? true;
  return wrapped;
}

function pdfError(error, pageCount) {
  const wrapped = new Error(
    `PDF（${pageCount} 页）识别失败：${error?.message || "未知错误"}`,
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
  pdfDataUrl,
  pageCount,
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  env,
  fetchImpl,
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
              pdfDataUrl,
              pageCount,
              imageDataUrls,
              filename,
              userInstruction,
            }),
          },
          ...(pdfDataUrl
            ? [{
                type: "input_file",
                filename,
                file_data: pdfDataUrl,
                detail: pdfDetail(model.imageDetail),
              }]
            : imageDataUrls.map((imageDataUrl) => ({
                type: "input_image",
                image_url: imageDataUrl,
                detail: model.imageDetail || "auto",
              }))),
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
  pdfDataUrl,
  pageCount,
  filename,
  schema = SLATE_SCHEMA,
  systemPrompt = SYSTEM_PROMPT,
  userInstruction,
  env,
  fetchImpl,
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

  const initialJsonMode = chatJsonMode(provider, model);
  let data;
  try {
    data = await postChatCompletions(
      provider,
      buildChatCompletionsPayload({
        provider,
        model,
        imageDataUrls,
        pdfDataUrl,
        pageCount,
        filename,
        schema,
        systemPrompt,
        userInstruction,
        jsonMode: initialJsonMode,
      }),
      headers,
      fetchImpl,
    );
  } catch (error) {
    const fallbackJsonMode = nextChatJsonMode(initialJsonMode, error);
    if (!fallbackJsonMode) {
      throw error;
    }

    data = await postChatCompletions(
      provider,
      buildChatCompletionsPayload({
        provider,
        model,
        imageDataUrls,
        pdfDataUrl,
        pageCount,
        filename,
        schema,
        systemPrompt,
        userInstruction,
        jsonMode: fallbackJsonMode,
      }),
      headers,
      fetchImpl,
    );
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
  pdfDataUrl,
  pageCount,
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
              pdfDataUrl,
              pageCount,
              imageDataUrls,
              filename,
              userInstruction,
            }),
          },
          ...(pdfDataUrl
            ? [{
                type: "file",
                file: {
                  filename,
                  file_data: pdfDataUrl,
                },
              }]
            : imageDataUrls.map((imageDataUrl) => ({
                type: "image_url",
                image_url: {
                  url: imageDataUrl,
                },
              }))),
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
  pdfDataUrl,
  pageCount,
  imageDataUrls = [],
  filename,
  userInstruction,
}) {
  const base = pdfDataUrl
    ? `识别这份完整 PDF 场记单，共 ${pageCount} 页。来源文件名：${filename}`
    : imageDataUrls.length > 1
      ? `以下 ${imageDataUrls.length} 张图是同一个来源页的整页图与局部放大图，必须合并为一页识别，不能重复输出记录。来源：${filename}`
      : `识别这一页场记单。来源：${filename}`;
  return userInstruction ? `${base}\n\n${userInstruction}` : base;
}

async function postChatCompletions(provider, payload, headers, fetchImpl) {
  const data = await postJson(
    `${provider.baseUrl}/chat/completions`,
    payload,
    headers,
    fetchImpl,
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

async function postJson(url, payload, headers, fetchImpl) {
  let response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    if (error.name === "TimeoutError") {
      throw providerError("模型请求超时，请稍后重试", 504);
    }
    throw providerError(`无法连接模型服务：${error.message}`, 502);
  }

  const raw = await response.text();
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

function isSupportedPdfDataUrl(value) {
  return (
    typeof value === "string" &&
    /^data:application\/pdf;base64,[A-Za-z0-9+/=\s]+$/.test(value)
  );
}

function normalizePageCount(value) {
  const count = Number(value);
  return Number.isInteger(count) && count >= 1 && count <= 20 ? count : null;
}

function skippedDirectPdfOcr(env) {
  const status = paddleOcrPublicConfig(env, { autoEnable: env === process.env });
  if (status.enabled && status.required) {
    throw clientError(
      "当前接口直接提交的 Base64 PDF 无法运行必需的 PaddleOCR；请改为逐页图片，或关闭 PADDLEOCR_REQUIRED。",
      400,
    );
  }
  return {
    ...status,
    used: false,
    pages: [],
    durationMs: 0,
    warning: status.enabled
      ? "直接提交 Base64 PDF 的兼容路径未运行 PaddleOCR；网页上传会先转成页面图片并启用 OCR。"
      : null,
  };
}

function pdfDetail(imageDetail) {
  return imageDetail === "high" || imageDetail === "low"
    ? imageDetail
    : imageDetail === "original"
      ? "high"
      : "auto";
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
