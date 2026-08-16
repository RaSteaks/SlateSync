// Electron (Node fs) mirror of the browser metadata discovery in
// public/slate-directory.js. Same walk/prune/learn/probe/fallback algorithm,
// implemented against the filesystem instead of File System Access API handles.
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { extractCombinedMaterialKey } from "../public/metadata-common.js";
import {
  METADATA_FILE_PATTERN,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";
import {
  defaultMetadataStructure,
  learnStructure,
  probeNames,
} from "../public/metadata-structure.js";

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
  const structureByCamera = new Map();
  const stats = {
    visitedDirectories: 0,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 0,
    readSlateFiles: 0,
    learnedStructures: 0,
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

      const camera = directoryKey.split(":")[0];
      let structure = structureByCamera.get(camera);
      if (!structure) {
        structure = defaultMetadataStructure();
        structureByCamera.set(camera, structure);
      }

      // Probe the known naming convention directly (no enumeration).
      for (const candidateName of probeNames(structure, dirName)) {
        const candidatePath = join(currentPath, candidateName);
        try {
          const fileStat = await stat(candidatePath);
          if (fileStat.isFile()) {
            candidates.push({
              filePath: candidatePath,
              sourceName: [...pathParts, candidateName].join("/"),
            });
            stats.discoveredSlateFiles += 1;
            return;
          }
        } catch {
          // not found, try the next candidate
        }
      }

      // Probe missed → enumerate once, learn the real structure, remember.
      const found = await listMetadataFiles(currentPath, pathParts);
      if (found.length) {
        structureByCamera.set(
          camera,
          learnStructure(dirName, found.map((file) => file.name)),
        );
        stats.learnedStructures += 1;
        for (const file of found) {
          candidates.push({ filePath: file.filePath, sourceName: file.sourceName });
          stats.discoveredSlateFiles += 1;
        }
      }
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
        if (!METADATA_FILE_PATTERN.test(entry.name)) continue;
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

  async function listMetadataFiles(currentPath, pathParts) {
    const found = [];
    let entries;
    try {
      entries = await readdir(currentPath, { withFileTypes: true });
    } catch (error) {
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
      return found;
    }
    for (const entry of entries) {
      if (entry.isFile() && METADATA_FILE_PATTERN.test(entry.name)) {
        found.push({
          name: entry.name,
          filePath: join(currentPath, entry.name),
          sourceName: [...pathParts, entry.name].join("/"),
        });
      }
    }
    return found;
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
      metadata.push(parseMetadataFile(arrayBuffer, candidate.sourceName));
    } catch (error) {
      warnings.push(error.message || `${candidate.sourceName} 无法读取`);
    }
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

  return { metadata, warnings, stats, missingKeys: [...missingKeys] };
}

function boundedInteger(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum
    ? number
    : fallback;
}
