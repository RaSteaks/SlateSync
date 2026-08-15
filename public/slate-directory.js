// Browser-side metadata discovery (File System Access API).
//
// Walks the selected material root and locates each clip's camera sidecar
// (slate.txt today; XML/ALE for other cameras later). The walk is driven by
// the Resolve CSV's material keys: directories whose name does not resolve to
// an expected material are pruned without enumerating their contents.
//
// The sidecar naming convention is learned per camera (机位): the first clip of
// a camera is enumerated to learn how its sidecar is named, then the remaining
// clips are found by a direct probe — falling back to enumeration when the
// probe misses, so nothing is silently dropped. Clips that end up with no
// sidecar are reported back via `missingKeys`.
import { extractCombinedMaterialKey } from "./metadata-common.js";
import {
  METADATA_FILE_PATTERN,
  parseMetadataFile,
} from "./metadata-sources/index.js";
import {
  defaultMetadataStructure,
  learnStructure,
  probeNames,
} from "./metadata-structure.js";

const DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024;

export async function scanSlateDirectory(rootHandle, options = {}) {
  if (!rootHandle || rootHandle.kind !== "directory") {
    throw new Error("请选择有效的素材根目录");
  }

  const expectedKeys = new Set(options.expectedKeys || []);
  if (!expectedKeys.size) {
    throw new Error("Resolve CSV 中没有可用于查找 slate.txt 的素材编号");
  }

  const maxDepth = boundedInteger(options.maxDepth, 4, 1, 12);
  const readConcurrency = boundedInteger(options.readConcurrency, 4, 1, 16);
  const maxFileBytes = boundedInteger(
    options.maxFileBytes,
    DEFAULT_MAX_FILE_BYTES,
    1,
    100 * 1024 * 1024,
  );
  const cache = options.cache instanceof Map ? options.cache : new Map();
  const signal = options.signal;
  const warnings = [];
  const candidates = new Map();
  const structureByCamera = new Map();
  const stats = {
    visitedDirectories: 0,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 0,
    readSlateFiles: 0,
    cacheHits: 0,
    learnedStructures: 0,
  };

  const rememberCandidate = (handle, pathParts) => {
    const sourceName = pathParts.join("/");
    if (candidates.has(sourceName)) return;
    candidates.set(sourceName, { handle, sourceName });
    stats.discoveredSlateFiles += 1;
  };

  const listMetadataFiles = async (directoryHandle, pathParts) => {
    const found = [];
    try {
      for await (const [name, handle] of directoryHandle.entries()) {
        throwIfAborted(signal);
        if (handle.kind !== "file" || !METADATA_FILE_PATTERN.test(name)) continue;
        found.push({ name, handle });
      }
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
    }
    return found;
  };

  const walk = async (directoryHandle, pathParts, depth, isRoot = false) => {
    throwIfAborted(signal);
    stats.visitedDirectories += 1;

    const directoryKey = isRoot
      ? ""
      : extractCombinedMaterialKey(directoryHandle.name);
    if (directoryKey) {
      if (!expectedKeys.has(directoryKey)) {
        stats.prunedDirectories += 1;
        return;
      }

      const camera = directoryKey.split(":")[0];
      let structure = structureByCamera.get(camera);
      if (!structure) {
        structure = defaultMetadataStructure();
        structureByCamera.set(camera, structure);
      }

      // Probe the known naming convention directly (no enumeration).
      for (const candidateName of probeNames(structure, directoryHandle.name)) {
        const handle = await optionalFileHandle(directoryHandle, candidateName);
        if (handle) {
          rememberCandidate(handle, [...pathParts, candidateName]);
          return;
        }
      }

      // Probe missed → enumerate once, learn the real structure, remember.
      const found = await listMetadataFiles(directoryHandle, pathParts);
      if (found.length) {
        structureByCamera.set(
          camera,
          learnStructure(directoryHandle.name, found.map((file) => file.name)),
        );
        stats.learnedStructures += 1;
        for (const { name, handle } of found) {
          rememberCandidate(handle, [...pathParts, name]);
        }
      }
      return;
    }

    const childDirectories = [];
    try {
      for await (const [name, handle] of directoryHandle.entries()) {
        throwIfAborted(signal);
        if (handle.kind === "file") {
          if (!METADATA_FILE_PATTERN.test(name)) continue;
          const fileKey = extractCombinedMaterialKey(name);
          if (!fileKey || expectedKeys.has(fileKey)) {
            rememberCandidate(handle, [...pathParts, name]);
          }
          continue;
        }
        if (handle.kind !== "directory") continue;

        const childKey = extractCombinedMaterialKey(name);
        if (childKey && !expectedKeys.has(childKey)) {
          stats.prunedDirectories += 1;
          continue;
        }
        if (depth >= maxDepth) {
          stats.skippedDeepDirectories += 1;
          continue;
        }
        childDirectories.push([name, handle]);
      }
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
      return;
    }

    for (const [name, handle] of childDirectories) {
      await walk(handle, [...pathParts, name], depth + 1);
    }
  };

  await walk(rootHandle, [rootHandle.name || "素材根目录"], 0, true);
  throwIfAborted(signal);

  const results = await mapWithConcurrency(
    [...candidates.values()],
    readConcurrency,
    async ({ handle, sourceName }) => {
      throwIfAborted(signal);
      let file;
      try {
        file = await handle.getFile();
        if (file.size > maxFileBytes) {
          return { warning: `${sourceName} 超过 2 MB，已跳过。` };
        }

        const cacheKey = `${sourceName}\u0000${file.size}\u0000${file.lastModified}`;
        if (cache.has(cacheKey)) {
          stats.cacheHits += 1;
          return cache.get(cacheKey);
        }

        stats.readSlateFiles += 1;
        const result = {
          metadata: parseMetadataFile(await file.arrayBuffer(), sourceName),
        };
        cache.set(cacheKey, result);
        return result;
      } catch (error) {
        if (error?.name === "AbortError") throw error;
        const result = {
          warning: error.message || `${sourceName} 无法读取`,
        };
        if (file) {
          const cacheKey = `${sourceName}\u0000${file.size}\u0000${file.lastModified}`;
          cache.set(cacheKey, result);
        }
        return result;
      }
    },
  );

  const metadata = [];
  for (const result of results) {
    if (result?.metadata) metadata.push(result.metadata);
    if (result?.warning) warnings.push(result.warning);
  }
  // Reconcile after parsing so expected clips with an entirely absent
  // directory are reported just like clips with an empty directory.
  const foundKeys = new Set(
    metadata.map((entry) => entry.materialKey).filter(Boolean),
  );
  const missingKeys = [...expectedKeys].filter((key) => !foundKeys.has(key));
  if (stats.skippedDeepDirectories) {
    warnings.push(
      `${stats.skippedDeepDirectories} 个目录超过配置的 ${maxDepth} 层搜索范围，未继续进入。`,
    );
  }

  return { metadata, warnings, stats, cache, missingKeys: [...missingKeys] };
}

async function optionalFileHandle(directoryHandle, name) {
  if (typeof directoryHandle.getFileHandle !== "function") return null;
  try {
    return await directoryHandle.getFileHandle(name);
  } catch (error) {
    if (["NotFoundError", "TypeMismatchError"].includes(error?.name)) {
      return null;
    }
    throw error;
  }
}

async function mapWithConcurrency(items, concurrency, mapper) {
  const output = Array(items.length);
  let cursor = 0;
  async function worker() {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      output[index] = await mapper(items[index], index);
    }
  }
  await Promise.all(
    Array.from(
      { length: Math.min(concurrency, Math.max(1, items.length)) },
      worker,
    ),
  );
  return output;
}

function boundedInteger(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum
    ? number
    : fallback;
}

function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  const error = new Error("slate.txt 目录扫描已取消");
  error.name = "AbortError";
  throw error;
}
