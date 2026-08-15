// Kinefinity metadata source: the camera writes a plain-text `slate.txt`
// sidecar per clip, using a `Key: Value` layout. We read `Clip Name`,
// `Sensor FPS` and `Shot Date` and normalise them into the canonical metadata
// shape consumed by buildSlateMetadataIndex / mergeSlateIntoResolveTable.

import {
  canonicalKeyToMaterialPrefix,
  detectCsvFormat,
  extractCombinedMaterialKey,
  normalizeCameraFps,
  normalizeShootDay,
} from "../metadata-common.js";

const SLATE_FILE_PATTERN = /slate\.txt$/i;

export const kinefinityMetadataSource = {
  id: "kinefinity",
  label: "Kinefinity slate.txt",
  filePatterns: [SLATE_FILE_PATTERN],
  detect(sourceName) {
    return SLATE_FILE_PATTERN.test(String(sourceName || ""));
  },
  parse(input, sourceName) {
    return parseSlateMetadataText(input, sourceName);
  },
};

export function parseSlateMetadataText(input, sourceName = "slate.txt") {
  const text = decodeSlateMetadataText(input);
  const fields = new Map();
  for (const line of text.replace(/^\uFEFF/, "").split(/\r\n|\n|\r/)) {
    const match = line.match(/^\s*([^:]+?)\.*\s*:\s*(.*?)\s*$/);
    if (!match) continue;
    const key = match[1].replace(/[.\s]+$/g, "").trim().toLowerCase();
    if (key && !fields.has(key)) fields.set(key, match[2].trim());
  }

  const clipName = fields.get("clip name") || "";
  const clipKey = extractCombinedMaterialKey(clipName);
  const sourceBaseName = String(sourceName || "")
    .split(/[\\/]/)
    .filter(Boolean)
    .at(-1);
  const sourceKey = extractCombinedMaterialKey(sourceBaseName);
  if (fields.has("clip name") && !clipKey) {
    throw new Error(`${sourceName} 的 Clip Name“${clipName}”无法识别`);
  }
  if (clipKey && sourceKey && clipKey !== sourceKey) {
    throw new Error(
      `${sourceName} 的 Clip Name“${clipName}”与文件名指向不同素材`,
    );
  }
  const materialKey = clipKey || sourceKey;
  if (!materialKey) {
    throw new Error(`${sourceName} 缺少可识别的 Clip Name`);
  }

  const sensorFps = normalizeCameraFps(fields.get("sensor fps"));
  const shootDay = normalizeShootDay(fields.get("shot date"));
  if (!sensorFps && !shootDay) {
    throw new Error(`${sourceName} 缺少有效的 Sensor FPS 或 Shot Date`);
  }

  return {
    sourceName: String(sourceName || "slate.txt"),
    clipName: clipName || canonicalKeyToMaterialPrefix(materialKey),
    materialKey,
    sensorFps,
    shootDay,
  };
}

function decodeSlateMetadataText(input) {
  if (typeof input === "string") return input;
  const bytes =
    input instanceof Uint8Array
      ? input
      : input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : null;
  if (!bytes?.length) throw new Error("slate.txt 文件为空");

  const format = detectCsvFormat(bytes);
  try {
    return new TextDecoder(format.encoding, { fatal: true }).decode(
      bytes.subarray(format.bomBytes),
    );
  } catch {
    throw new Error("无法读取 slate.txt 编码；仅支持 UTF-8 或 UTF-16 文本。");
  }
}
