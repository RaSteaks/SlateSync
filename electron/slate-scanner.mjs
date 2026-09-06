// Electron metadata discovery implemented against Node.js filesystem APIs.
// The scanner prunes unrelated material directories, learns camera-specific
// filename structures, and falls back to bounded directory enumeration.
// 两类元数据来源，同一目录下互斥出现（侧车优先）：
//   - 外置侧车：slate.txt 等（Kinefinity），整文件读取（默认 ≤2MB）
//   - 内嵌元数据：DJI 等把信息写进 MOV/MP4 容器，只定位读取 moov atom，
//     绝不读取媒体数据本体
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { extractCombinedMaterialKey } from "../public/metadata-common.js";
import {
  METADATA_FILE_PATTERN,
  parseMetadataFile,
} from "../public/metadata-sources/index.js";
import { QUICKTIME_FILE_PATTERN } from "../public/metadata-sources/quicktime.js";
import {
  DEFAULT_MAX_MOOV_BYTES,
  readQuickTimeMoov,
} from "./quicktime-meta-reader.mjs";
import {
  defaultMetadataStructure,
  learnStructure,
  probeNames,
} from "../public/metadata-structure.js";

const DEFAULT_MAX_FILE_BYTES = 2 * 1024 * 1024;
// maxMoovBytes 可配下限：防止误配过小值导致正常素材的 moov 一律被拒
const MIN_MAX_MOOV_BYTES = 64 * 1024;

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
  // 内嵌元数据只读 moov atom；该上限约束的是 moov 本身（异常膨胀防护），
  // 与视频文件体积无关
  const maxMoovBytes = boundedInteger(
    options.maxMoovBytes,
    DEFAULT_MAX_MOOV_BYTES,
    MIN_MAX_MOOV_BYTES,
    512 * 1024 * 1024,
  );
  const warnings = [];
  const candidates = [];
  const structureByCamera = new Map();
  const stats = {
    visitedDirectories: 0,
    prunedDirectories: 0,
    skippedDeepDirectories: 0,
    discoveredSlateFiles: 0,
    discoveredVideoFiles: 0,
    readSlateFiles: 0,
    readVideoFiles: 0,
    learnedStructures: 0,
  };

  async function walk(currentPath, pathParts, depth, isRoot = false) {
    stats.visitedDirectories += 1;

    const dirName = pathParts[pathParts.length - 1] || "";
    const directoryKey = isRoot ? "" : extractCombinedMaterialKey(dirName);

    if (directoryKey) {
      // Pruned clip directories never reach walk(); they are intercepted in
      // the parent's enumeration below, which probes them for a sidecar
      // before skipping the subtree. Reaching this branch means an expected
      // clip directory was visited directly.
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
              isVideo: false,
            });
            stats.discoveredSlateFiles += 1;
            return;
          }
        } catch {
          // not found, try the next candidate
        }
      }

      // Probe missed → enumerate once, learn the real structure, remember.
      const sidecars = await listDirectoryEntries(currentPath, pathParts, directoryKey);
      const found = sidecars.filter((file) => !file.isVideo);
      if (found.length) {
        structureByCamera.set(
          camera,
          learnStructure(dirName, found.map((file) => file.name)),
        );
        stats.learnedStructures += 1;
        for (const file of found) {
          candidates.push({ filePath: file.filePath, sourceName: file.sourceName, isVideo: false });
          stats.discoveredSlateFiles += 1;
        }
        return;
      }

      // 侧车未命中 → 使用同一次目录枚举寻找内嵌元数据的视频文件
      //（两类来源互斥，侧车优先；视频须与所在片段目录指向同一素材，防止
      // 错位文件被静默误归属到别的素材行）。
      const videos = sidecars.filter((file) => file.isVideo);
      for (const file of videos) {
        candidates.push({ filePath: file.filePath, sourceName: file.sourceName, isVideo: true });
        stats.discoveredVideoFiles += 1;
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
        // 按扩展名区分外置侧车与内嵌元数据视频。侧车允许无键名（内容键裁决）；
        // 视频必须带键名——目录里常有不含素材键的手机花絮等视频，宽松接纳会
        // 造成大量无意义的 moov 读取与警告，且其内容键大概率不在本 CSV 内。
        const isVideo = QUICKTIME_FILE_PATTERN.test(entry.name);
        const fileKey = extractCombinedMaterialKey(entry.name);
        if (isVideo && !fileKey) continue;
        if (fileKey && !expectedKeys.has(fileKey)) continue;
        candidates.push({
          filePath: join(currentPath, entry.name),
          sourceName: [...pathParts, entry.name].join("/"),
          isVideo,
        });
        if (isVideo) stats.discoveredVideoFiles += 1;
        else stats.discoveredSlateFiles += 1;
        continue;
      }
      if (!entry.isDirectory()) continue;

      const childKey = extractCombinedMaterialKey(entry.name);
      if (childKey && !expectedKeys.has(childKey)) {
        // A clip directory outside this Resolve CSV is pruned from the walk.
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

  // 单次 readdir 同时枚举侧车与内嵌元数据视频候选（METADATA_FILE_PATTERN 是
  // 全部来源的并集，覆盖两类文件）：
  //   - 侧车（slate.txt 等）：允许无键名，归属由解析出的内容键裁决；
  //   - 视频（MOV/MP4）：必须带素材键且属于本 CSV（过滤手机花絮等无关视频、
  //     避免无意义 moov 读取）；clipDirectoryKey 非空时还要求与所在片段目录
  //     指向同一素材，防止错位文件被静默误归属到别的素材行。
  async function listDirectoryEntries(currentPath, pathParts, clipDirectoryKey = "") {
    const found = [];
    let entries;
    try {
      entries = await readdir(currentPath, { withFileTypes: true });
    } catch (error) {
      warnings.push(`${pathParts.join("/")} 无法读取：${error.message}`);
      return found;
    }
    for (const entry of entries) {
      if (!entry.isFile() || !METADATA_FILE_PATTERN.test(entry.name)) continue;
      const isVideo = QUICKTIME_FILE_PATTERN.test(entry.name);
      const fileKey = extractCombinedMaterialKey(entry.name);
      if (isVideo) {
        if (!fileKey || !expectedKeys.has(fileKey)) continue;
        if (clipDirectoryKey && fileKey !== clipDirectoryKey) continue;
      } else if (fileKey && !expectedKeys.has(fileKey)) continue;
      found.push({
        name: entry.name,
        isVideo,
        filePath: join(currentPath, entry.name),
        sourceName: [...pathParts, entry.name].join("/"),
      });
    }
    return found;
  }

  const rootName = dirPath.split("/").filter(Boolean).pop() || "素材根目录";
  await walk(dirPath, [rootName], 0, true);

  // Read and parse every candidate file. Only sidecars whose content-derived
  // material key belongs to this Resolve CSV are kept as matched metadata;
  // anything else (including clips absent from the CSV) is ignored.
  const metadata = [];
  for (const candidate of candidates) {
    const parsed = await readCandidate(candidate);
    if (!parsed || !parsed.materialKey) continue;
    if (!expectedKeys.has(parsed.materialKey)) continue;
    metadata.push(parsed);
  }

  async function readCandidate(candidate) {
    try {
      // 内嵌元数据：视频文件不整读，只定位并读取承载元数据的 moov atom。
      // 2MB 侧车上限与巨型视频文件无关，因此分流到专属读取路径。
      if (candidate.isVideo) {
        stats.readVideoFiles += 1;
        let moov;
        try {
          moov = await readQuickTimeMoov(candidate.filePath, maxMoovBytes);
        } catch (error) {
          // 读取器报错不含路径，这里统一补上素材显示名
          throw new Error(`${candidate.sourceName} ${error.message}`);
        }
        if (!moov) {
          warnings.push(
            `${candidate.sourceName} 不是有效的 QuickTime 文件，未找到 moov 元数据`,
          );
          return null;
        }
        return parseMetadataFile(moov, candidate.sourceName);
      }

      const fileStat = await stat(candidate.filePath);
      if (fileStat.size > maxFileBytes) {
        warnings.push(
          `${candidate.sourceName} 超过 ${Math.floor(maxFileBytes / 1024 / 1024)} MB，已跳过。`,
        );
        return null;
      }
      stats.readSlateFiles += 1;
      const buffer = await readFile(candidate.filePath);
      const arrayBuffer = buffer.buffer.slice(
        buffer.byteOffset,
        buffer.byteOffset + buffer.byteLength,
      );
      return parseMetadataFile(arrayBuffer, candidate.sourceName);
    } catch (error) {
      warnings.push(error.message || `${candidate.sourceName} 无法读取`);
      return null;
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

  return {
    metadata,
    warnings,
    stats,
    missingKeys: [...missingKeys],
  };
}

function boundedInteger(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum
    ? number
    : fallback;
}
