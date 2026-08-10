import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import {
  extractCombinedMaterialKey,
  parseSlateMetadataText,
} from "../public/resolve-csv.js";

const SLATE_FILE_PATTERN = /slate\.txt$/i;
const DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024;

export function createSlateScanner() {
  return { scan: scanSlateDirectory };
}

async function scanSlateDirectory(dirPath, options = {}) {
  const expectedKeys = new Set(options.expectedKeys || []);
  if (!expectedKeys.size) {
    throw new Error("Resolve CSV 中没有可用于查找 slate.txt 的素材编号");
  }

  const maxDepth = boundedInteger(options.maxDepth, 4, 1, 12);
  const maxFileBytes = boundedInteger(
    options.maxFileBytes,
    DEFAULT_MAX_FILE_BYTES,
    1,
    100 * 1024 * 1024,
  );
  const warnings = [];
  const candidates = [];
  const stats = {
    visitedDirectories: 0,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 0,
    readSlateFiles: 0,
  };

  async function walk(currentPath, pathParts, depth, isRoot = false) {
    stats.visitedDirectories += 1;

    const dirName = pathParts[pathParts.length - 1] || "";
    const directoryKey = isRoot ? "" : extractCombinedMaterialKey(dirName);

    if (directoryKey) {
      if (!expectedKeys.has(directoryKey)) {
        stats.prunedDirectories += 1;
        return;
      }

      // Check for exact match: <dirname>-slate.txt
      const exactName = `${dirName}-slate.txt`;
      const exactPath = join(currentPath, exactName);
      try {
        const fileStat = await stat(exactPath);
        if (fileStat.isFile()) {
          candidates.push({ filePath: exactPath, sourceName: [...pathParts, exactName].join("/") });
          stats.discoveredSlateFiles += 1;
          return;
        }
      } catch {
        // exact match not found, enumerate all slate.txt in this directory
      }

      await enumerateFilesOnly(currentPath, pathParts);
      return;
    }

    let entries;
    try {
      entries = await readdir(currentPath, { withFileTypes: true });
    } catch (error) {
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
      return;
    }

    const childDirectories = [];
    for (const entry of entries) {
      if (entry.isFile()) {
        if (!SLATE_FILE_PATTERN.test(entry.name)) continue;
        const fileKey = extractCombinedMaterialKey(entry.name);
        if (!fileKey || expectedKeys.has(fileKey)) {
          candidates.push({
            filePath: join(currentPath, entry.name),
            sourceName: [...pathParts, entry.name].join("/"),
          });
          stats.discoveredSlateFiles += 1;
        }
        continue;
      }
      if (!entry.isDirectory()) continue;

      const childKey = extractCombinedMaterialKey(entry.name);
      if (childKey && !expectedKeys.has(childKey)) {
        stats.prunedDirectories += 1;
        continue;
      }
      if (depth >= maxDepth) {
        stats.skippedDeepDirectories += 1;
        continue;
      }
      childDirectories.push(entry.name);
    }

    for (const name of childDirectories) {
      await walk(join(currentPath, name), [...pathParts, name], depth + 1);
    }
  }

  async function enumerateFilesOnly(currentPath, pathParts) {
    let entries;
    try {
      entries = await readdir(currentPath, { withFileTypes: true });
    } catch (error) {
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
      return;
    }
    for (const entry of entries) {
      if (entry.isFile() && SLATE_FILE_PATTERN.test(entry.name)) {
        candidates.push({
          filePath: join(currentPath, entry.name),
          sourceName: [...pathParts, entry.name].join("/"),
        });
        stats.discoveredSlateFiles += 1;
      }
    }
  }

  const rootName = dirPath.split("/").filter(Boolean).pop() || "素材根目录";
  await walk(dirPath, [rootName], 0, true);

  // Read and parse all candidate files
  const metadata = [];
  for (const candidate of candidates) {
    try {
      const fileStat = await stat(candidate.filePath);
      if (fileStat.size > maxFileBytes) {
        warnings.push(
          `${candidate.sourceName} 超过 ${Math.floor(maxFileBytes / 1024 / 1024)} MB，已跳过。`,
        );
        continue;
      }
      stats.readSlateFiles += 1;
      const buffer = await readFile(candidate.filePath);
      const arrayBuffer = buffer.buffer.slice(
        buffer.byteOffset,
        buffer.byteOffset + buffer.byteLength,
      );
      metadata.push(parseSlateMetadataText(arrayBuffer, candidate.sourceName));
    } catch (error) {
      warnings.push(error.message || `${candidate.sourceName} 无法读取`);
    }
  }

  if (stats.skippedDeepDirectories) {
    warnings.push(
      `${stats.skippedDeepDirectories} 个目录超过配置的 ${maxDepth} 层搜索范围，未继续进入。`,
    );
  }

  return { metadata, warnings, stats };
}

function boundedInteger(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum
    ? number
    : fallback;
}
