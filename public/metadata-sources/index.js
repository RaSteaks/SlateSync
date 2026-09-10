// Metadata source registry. Adding support for another camera vendor means
// adding one adapter file here (DJI SRT/XML, RED R3D sidecar, …) and
// registering it in METADATA_SOURCES — the discovery and merge layers below
// stay unchanged.
//
// Adapter contract (duck-typed):
//   { id, label, filePatterns: [RegExp], detect?(sourceName, input),
//     parse(input, sourceName), parseEntries?(input, sourceName) }
//   - parse returns one canonical entry
//     { sourceName, clipName, materialKey, sensorFps, shootDay };
//     multi-clip formats (ALE) additionally define parseEntries returning
//     entry[] and their parse rejects with a pointer to the batch API.
//   - entries may carry an optional `extra` object (scene/take/TC…) which the
//     merge layer ignores for now.
//   - detect() receives (fileName, input) where input is the whole file
//     (sidecars) or the moov atom bytes (QuickTime containers); sources on the
//     same file extension must decide by content so exactly one matches.

import { kinefinityMetadataSource } from "./kinefinity.js";
import { arriQuicktimeMetadataSource } from "./arri-quicktime.js";
import { quicktimeMetadataSource } from "./quicktime.js";
import { arriXmlMetadataSource } from "./arri-xml.js";
import { arriAleMetadataSource } from "./arri-ale.js";

export const METADATA_SOURCES = [
  kinefinityMetadataSource,
  arriQuicktimeMetadataSource,
  quicktimeMetadataSource,
  arriXmlMetadataSource,
  arriAleMetadataSource,
];

// Union of every source's file patterns, used by the directory walkers to
// decide which files are metadata sidecars at all (instead of a hardcoded
// /slate\.txt$/i).
export const METADATA_FILE_PATTERN = buildUnionFilePattern(METADATA_SOURCES);

// Dispatches a discovered candidate file to the matching source and returns
// canonical metadata ({ materialKey, sensorFps, shootDay }). For multi-clip
// formats (ALE) this rejects — use parseMetadataEntries instead.
export function parseMetadataFile(input, sourceName = "") {
  return resolveMetadataSource(input, sourceName).parse(input, sourceName);
}

// Batch dispatch: returns entry[] for every source. Single-clip sources
// resolve to a one-element array; multi-clip sources (ALE parseEntries) are
// flattened, one entry per recognized clip.
export function parseMetadataEntries(input, sourceName = "") {
  const source = resolveMetadataSource(input, sourceName);
  const result = source.parseEntries
    ? source.parseEntries(input, sourceName)
    : source.parse(input, sourceName);
  return Array.isArray(result) ? result : [result];
}

function resolveMetadataSource(input, sourceName) {
  const name = String(sourceName || "");
  const matches = METADATA_SOURCES.filter((source) =>
    source.detect
      ? Boolean(source.detect(name, input))
      : source.filePatterns.some((pattern) => pattern.test(name)),
  );

  if (matches.length === 1) return matches[0];
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
