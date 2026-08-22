// Scenario Profile primitives.
//
// A profile describes the observed layout of a slate form and the canonical
// fields that the recognition pipeline should extract. It is intentionally
// derived from OCR evidence rather than bundled as a vendor-specific template.
import { createHash } from "node:crypto";

export const SCENARIO_SCHEMA_VERSION = 1;
export const FINGERPRINT_VERSION = 1;
export const DEFAULT_SCENARIO_MATCHING = Object.freeze({
  threshold: 0.85,
  ambiguityMargin: 0.05,
});

export const CANONICAL_SCENARIO_FIELDS = Object.freeze({
  cardNumber: {
    label: "卷号",
    aliases: ["卷号", "卡号", "卡", "card", "reel"],
  },
  videoCode: {
    label: "视频码",
    aliases: ["视频号", "视频码", "条号", "clip", "clip name"],
  },
  scene: {
    label: "场次",
    aliases: ["场次", "场景", "scene"],
  },
  shot: {
    label: "镜",
    aliases: ["镜", "镜号", "shot"],
  },
  take: {
    label: "次",
    aliases: ["次", "条次", "take"],
  },
  takeStatus: {
    label: "条次状态",
    aliases: ["过", "保", "废条", "状态", "status"],
  },
  description: {
    label: "拍摄内容",
    aliases: ["拍摄内容", "内容", "内容/视效说明", "description"],
  },
  comments: {
    label: "备注",
    aliases: ["备注", "注释", "comment", "comments"],
  },
  shotSize: {
    label: "景别",
    aliases: ["景别", "shot size"],
  },
  cameraPosition: {
    label: "机位",
    aliases: ["机位", "camera position"],
  },
});

export function createScenarioObservation(ocrResult, options = {}) {
  const pages = normalizeOcrPages(ocrResult?.pages);
  const views = pages.flatMap((page) => page.views);
  const blocks = views.flatMap((view) => view.blocks);
  const headerBlocks = blocks.filter((block) => block.bbox[1] <= 0.35);
  const headerTokens = uniqueSorted(
    headerBlocks
      .map((block) => normalizeToken(block.text))
      .filter((token) => token && token.length <= 40),
  );
  const cameraGroups = uniqueSorted(
    blocks
      .map((block) => normalizeToken(block.text))
      .filter((token) => /^[A-Z一二三四]机$/.test(token) || /^[A-D]CAM$/i.test(token)),
  );
  const columnBands = quantizedBands(blocks.map((block) => center(block.bbox)[0]));
  const rowBands = quantizedBands(blocks.map((block) => center(block.bbox)[1]));
  const aliases = detectFieldAliases(headerTokens);
  const layout = {
    pages: pages.map((page) => ({
      pageNumber: page.pageNumber,
      views: page.views.map((view) => ({
        width: view.width,
        height: view.height,
        orientation: orientation(view.width, view.height),
        blockCount: view.blocks.length,
      })),
    })),
    headerTokens,
    cameraGroups,
    columnBands,
    rowBands,
    blockCount: blocks.length,
  };
  const fingerprint = fingerprintForLayout(layout);
  const fieldRegions = inferFieldRegions(blocks, aliases);
  return {
    schemaVersion: SCENARIO_SCHEMA_VERSION,
    fingerprintVersion: FINGERPRINT_VERSION,
    fingerprint,
    label: cleanLabel(options.filename),
    layout,
    fields: createFieldProfiles(aliases, fieldRegions),
    source: {
      filename: cleanLabel(options.filename),
      pageCount: pages.length,
      ocrEngine: ocrResult?.id || null,
      ocrUsed: Boolean(ocrResult?.used),
    },
  };
}

export function profileFromObservation(observation, options = {}) {
  const fieldFormats = options.fieldFormats || {
    scene: "XXX",
    shot: "XX",
    take: "XX",
  };
  const comments = options.comments || { goodTake: "_OK", holdTake: "_KP" };
  return normalizeScenarioProfile({
    schemaVersion: SCENARIO_SCHEMA_VERSION,
    fingerprintVersion: observation.fingerprintVersion,
    fingerprint: observation.fingerprint,
    label: observation.label || "自动学习场记结构",
    layout: observation.layout,
    fields: observation.fields,
    recognition: {
      headerTokens: observation.layout?.headerTokens || [],
      promptHints: [
        "优先依据当前 Profile 提供的字段区域、表头和行列结构识别；结构不确定时返回 null，不要猜测。",
      ],
    },
    output: {
      resolve: { fieldFormats, comments },
    },
  });
}

export function normalizeScenarioProfile(value, options = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("场记结构 Profile 必须是 JSON 对象");
  }
  const layout = normalizeLayout(value.layout);
  const fields = normalizeFields(value.fields);
  const fingerprint = cleanToken(value.fingerprint) || fingerprintForLayout(layout);
  const output = normalizeOutput(value.output, options);
  const promptHints = Array.isArray(value.recognition?.promptHints)
    ? value.recognition.promptHints
        .filter((item) => typeof item === "string")
        .map((item) => item.trim().slice(0, 1000))
        .filter(Boolean)
        .slice(0, 20)
    : [];
  return {
    schemaVersion: SCENARIO_SCHEMA_VERSION,
    fingerprintVersion: integer(value.fingerprintVersion, FINGERPRINT_VERSION),
    fingerprint,
    label: cleanLabel(value.label) || "自动学习场记结构",
    layout,
    fields,
    recognition: {
      headerTokens: Array.isArray(value.recognition?.headerTokens)
        ? uniqueSorted(value.recognition.headerTokens.map(normalizeToken).filter(Boolean))
        : layout.headerTokens,
      promptHints,
    },
    output,
  };
}

export function publicScenarioProfile(profile) {
  const normalized = normalizeScenarioProfile(profile);
  return {
    schemaVersion: normalized.schemaVersion,
    fingerprintVersion: normalized.fingerprintVersion,
    fingerprint: normalized.fingerprint,
    label: normalized.label,
    layout: normalized.layout,
    fields: normalized.fields,
    recognition: normalized.recognition,
    output: normalized.output,
  };
}

export function scenarioPromptInstruction(profile) {
  const normalized = normalizeScenarioProfile(profile);
  const layout = normalized.layout;
  const fields = Object.entries(normalized.fields)
    .filter(([, field]) => field.region)
    .map(([name, field]) => `${name}=${field.region.join(",")}`)
    .join("; ");
  const headers = normalized.recognition.headerTokens.join("、") || "无可靠表头";
  const hints = normalized.recognition.promptHints.join("；");
  return `\n\n当前场记结构 Profile：${normalized.label}。版式表头：${headers}。摄影机区块：${layout.cameraGroups.join("、") || "未确认"}。字段区域（归一化坐标）：${fields || "未确认"}。${hints ? `补充提示：${hints}。` : ""}这些是版式辅助证据，仍须以当前图片为准；无法确认的字段返回 null。`;
}

export function fingerprintForLayout(layout) {
  return sha256(stableStringify({
    version: FINGERPRINT_VERSION,
    pages: layout.pages,
    headerTokens: layout.headerTokens,
    cameraGroups: layout.cameraGroups,
    columnBands: layout.columnBands,
    rowBands: layout.rowBands,
  })).slice(0, 32);
}

export function scenarioSimilarity(left, right) {
  const a = normalizeScenarioProfile(left);
  const b = normalizeScenarioProfile(right);
  if (a.fingerprint === b.fingerprint) return 1;
  const pageScore = comparePageShapes(a.layout.pages, b.layout.pages);
  const headerScore = jaccard(a.layout.headerTokens, b.layout.headerTokens);
  const cameraScore = jaccard(a.layout.cameraGroups, b.layout.cameraGroups);
  const columnScore = bandScore(a.layout.columnBands, b.layout.columnBands);
  const rowScore = bandScore(a.layout.rowBands, b.layout.rowBands);
  return Number((
    pageScore * 0.2 +
    headerScore * 0.4 +
    cameraScore * 0.15 +
    columnScore * 0.15 +
    rowScore * 0.1
  ).toFixed(6));
}

export function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (!value || typeof value !== "object") return JSON.stringify(value);
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}

function normalizeOcrPages(pages) {
  if (!Array.isArray(pages)) return [];
  return pages.map((page, pageIndex) => {
    const views = Array.isArray(page?.views) ? page.views : [];
    return {
      pageNumber: integer(page?.pageNumber, pageIndex + 1),
      views: views.map((view) => {
        const rawBlocks = Array.isArray(view?.blocks) ? view.blocks : [];
        const blocks = rawBlocks.map((block) => ({
          text: cleanToken(block?.text),
          confidence: number(block?.confidence, 0),
          bbox: normalizeBbox(block?.bboxNormalized),
        })).filter((block) => block.text && block.bbox);
        return {
          width: integer(view?.width, 0),
          height: integer(view?.height, 0),
          blocks,
        };
      }),
    };
  });
}

function normalizeLayout(layout = {}) {
  return {
    pages: Array.isArray(layout.pages) ? layout.pages.map((page) => ({
      pageNumber: integer(page?.pageNumber, 1),
      views: Array.isArray(page?.views) ? page.views.map((view) => ({
        width: integer(view?.width, 0),
        height: integer(view?.height, 0),
        orientation: cleanToken(view?.orientation) || "unknown",
        blockCount: integer(view?.blockCount, 0),
      })) : [],
    })) : [],
    headerTokens: uniqueSorted((layout.headerTokens || []).map(normalizeToken).filter(Boolean)),
    cameraGroups: uniqueSorted((layout.cameraGroups || []).map(normalizeToken).filter(Boolean)),
    columnBands: normalizeBands(layout.columnBands),
    rowBands: normalizeBands(layout.rowBands),
    blockCount: integer(layout.blockCount, 0),
  };
}

function normalizeFields(fields = {}) {
  const result = {};
  for (const [field, definition] of Object.entries(CANONICAL_SCENARIO_FIELDS)) {
    const value = fields?.[field] || {};
    result[field] = {
      label: cleanLabel(value.label) || definition.label,
      aliases: uniqueSorted([
        ...definition.aliases,
        ...(Array.isArray(value.aliases) ? value.aliases : []),
      ].map(normalizeToken).filter(Boolean)),
      region: normalizeBbox(value.region),
      inherit: value.inherit === true,
      required: value.required === true,
    };
  }
  return result;
}

function normalizeOutput(output = {}, options = {}) {
  // Accept both the profile-shaped `{ output: { resolve } }` options and the
  // recognition config's flat `{ fieldFormats, comments }` options.
  const defaults = options.output?.resolve || {
    fieldFormats: options.fieldFormats,
    comments: options.comments,
  };
  const configured = output.resolve || {};
  const fieldFormats = {
    scene: safeFieldFormat(configured.fieldFormats?.scene || defaults.fieldFormats?.scene, "XXX"),
    shot: safeFieldFormat(configured.fieldFormats?.shot || defaults.fieldFormats?.shot, "XX"),
    take: safeFieldFormat(configured.fieldFormats?.take || defaults.fieldFormats?.take, "XX"),
  };
  const comments = {
    goodTake: safeCommentToken(configured.comments?.goodTake || defaults.comments?.goodTake, "_OK"),
    holdTake: safeCommentToken(configured.comments?.holdTake || defaults.comments?.holdTake, "_KP"),
  };
  return { resolve: { fieldFormats, comments } };
}

function safeFieldFormat(value, fallback) {
  const token = cleanToken(value);
  return /^X{1,6}$/.test(token) ? token : fallback;
}

function safeCommentToken(value, fallback) {
  const token = cleanToken(value).slice(0, 32);
  return token && !/[\r\n]/.test(token) ? token : fallback;
}

function detectFieldAliases(headerTokens) {
  const aliases = {};
  for (const [field, definition] of Object.entries(CANONICAL_SCENARIO_FIELDS)) {
    aliases[field] = headerTokens.filter((token) =>
      definition.aliases.some((alias) => token === normalizeToken(alias) || token.includes(normalizeToken(alias))),
    );
  }
  return aliases;
}

function createFieldProfiles(aliases, regions) {
  return Object.fromEntries(Object.entries(CANONICAL_SCENARIO_FIELDS).map(([field, definition]) => [
    field,
    {
      label: definition.label,
      aliases: uniqueSorted([...definition.aliases, ...(aliases[field] || [])].map(normalizeToken)),
      region: regions[field] || null,
      inherit: ["scene", "shot"].includes(field),
      required: ["scene", "shot", "take"].includes(field),
    },
  ]));
}

function inferFieldRegions(blocks, aliases) {
  const regions = {};
  for (const [field, tokens] of Object.entries(aliases)) {
    const matches = blocks.filter((block) => tokens.includes(normalizeToken(block.text)));
    if (!matches.length) continue;
    const box = matches.reduce((result, match) => unionBbox(result, match.bbox), null);
    regions[field] = box;
  }
  return regions;
}

function comparePageShapes(left, right) {
  if (!left.length || !right.length) return 0;
  const a = left[0]?.views?.[0];
  const b = right[0]?.views?.[0];
  if (!a || !b) return 0;
  if (a.orientation === b.orientation && a.width && b.width && a.height && b.height) {
    const ratio = Math.min(a.width / b.width, b.width / a.width);
    const heightRatio = Math.min(a.height / b.height, b.height / a.height);
    return (ratio + heightRatio) / 2;
  }
  return a.orientation === b.orientation ? 0.6 : 0;
}

function jaccard(left = [], right = []) {
  const a = new Set(left);
  const b = new Set(right);
  if (!a.size && !b.size) return 1;
  const intersection = [...a].filter((value) => b.has(value)).length;
  const union = new Set([...a, ...b]).size;
  return union ? intersection / union : 0;
}

function bandScore(left = [], right = []) {
  if (!left.length || !right.length) return 0;
  const distance = Math.abs(left.length - right.length) / Math.max(left.length, right.length);
  return Math.max(0, 1 - distance);
}

function quantizedBands(values) {
  return uniqueSorted(values.filter(Number.isFinite).map((value) => Number((value / 0.05).toFixed(0))));
}

function normalizeBands(values) {
  return uniqueSorted((Array.isArray(values) ? values : []).map((value) => integer(value, 0)));
}

function normalizeBbox(value) {
  if (!Array.isArray(value) || value.length !== 4) return null;
  const numbers = value.map(Number);
  if (!numbers.every(Number.isFinite)) return null;
  const [left, top, right, bottom] = numbers;
  if (left < 0 || top < 0 || right > 1 || bottom > 1 || right < left || bottom < top) return null;
  return [left, top, right, bottom].map((item) => Number(item.toFixed(6)));
}

function unionBbox(left, right) {
  if (!left) return right;
  if (!right) return left;
  return [
    Math.min(left[0], right[0]),
    Math.min(left[1], right[1]),
    Math.max(left[2], right[2]),
    Math.max(left[3], right[3]),
  ];
}

function center(bbox) {
  return [(bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2];
}

function orientation(width, height) {
  if (!width || !height) return "unknown";
  return width >= height ? "landscape" : "portrait";
}

function normalizeToken(value) {
  return cleanToken(value)?.normalize("NFKC").replace(/\s+/g, " ").toLowerCase() || "";
}

function cleanToken(value) {
  return typeof value === "string" ? value.trim() : "";
}

function cleanLabel(value) {
  return cleanToken(value).slice(0, 120);
}

function integer(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) ? number : fallback;
}

function number(value, fallback) {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : fallback;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort();
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
