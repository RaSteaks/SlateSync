// Metadata source registry. Adding support for another camera vendor means
// adding one adapter file here (ARRI XML, DJI SRT/XML, RED R3D sidecar, …)
// and registering it in METADATA_SOURCES — the discovery and merge layers
// below stay unchanged.

import { kinefinityMetadataSource } from "./kinefinity.js";

export const METADATA_SOURCES = [kinefinityMetadataSource];

// Union of every source's file patterns, used by the directory walkers to
// decide which files are metadata sidecars at all (instead of a hardcoded
// /slate\.txt$/i).
export const METADATA_FILE_PATTERN = buildUnionFilePattern(METADATA_SOURCES);

// Dispatches a discovered candidate file to the matching source and returns
// canonical metadata ({ materialKey, sensorFps, shootDay }).
export function parseMetadataFile(input, sourceName = "") {
  const name = String(sourceName || "");
  const matches = METADATA_SOURCES.filter((source) =>
    source.detect
      ? Boolean(source.detect(name, input))
      : source.filePatterns.some((pattern) => pattern.test(name)),
  );

  if (matches.length === 1) return matches[0].parse(input, name);
  if (matches.length > 1) {
    throw new Error(
      `元数据文件“${name || "(未命名)"}”同时匹配多个来源（${matches
        .map((source) => source.label)
        .join("、")}），无法确定解析器。`,
    );
  }
  throw new Error(`无法识别的元数据文件来源：“${name || "(未命名)"}”。`);
}

function buildUnionFilePattern(sources) {
  const alternatives = sources.flatMap((source) =>
    source.filePatterns.map((pattern) => pattern.source),
  );
  if (!alternatives.length) return /(?!)/;
  return new RegExp(
    alternatives.map((source) => `(?:${source})`).join("|"),
    "i",
  );
}
