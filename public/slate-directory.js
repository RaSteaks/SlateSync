import {
  extractCombinedMaterialKey,
  parseSlateMetadataText,
} from "./resolve-csv.js";

const SLATE_FILE_PATTERN = /slate\.txt$/i;
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
  const stats = {
    visitedDirectories: 0,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 0,
    readSlateFiles: 0,
    cacheHits: 0,
  };

  const rememberCandidate = (handle, pathParts) => {
    const sourceName = pathParts.join("/");
    if (candidates.has(sourceName)) return;
    candidates.set(sourceName, { handle, sourceName });
    stats.discoveredSlateFiles += 1;
  };

  const enumerateFilesOnly = async (directoryHandle, pathParts) => {
    try {
      for await (const [name, handle] of directoryHandle.entries()) {
        throwIfAborted(signal);
        if (handle.kind !== "file" || !SLATE_FILE_PATTERN.test(name)) continue;
        rememberCandidate(handle, [...pathParts, name]);
      }
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
    }
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

      const exactName = `${directoryHandle.name}-slate.txt`;
      const exactHandle = await optionalFileHandle(directoryHandle, exactName);
      if (exactHandle) {
        rememberCandidate(exactHandle, [...pathParts, exactName]);
        return;
      }

      await enumerateFilesOnly(directoryHandle, pathParts);
      return;
    }

    const childDirectories = [];
    try {
      for await (const [name, handle] of directoryHandle.entries()) {
        throwIfAborted(signal);
        if (handle.kind === "file") {
          if (!SLATE_FILE_PATTERN.test(name)) continue;
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
          metadata: parseSlateMetadataText(await file.arrayBuffer(), sourceName),
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
  if (stats.skippedDeepDirectories) {
    warnings.push(
      `${stats.skippedDeepDirectories} 个目录超过配置的 ${maxDepth} 层搜索范围，未继续进入。`,
    );
  }

  return { metadata, warnings, stats, cache };
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
