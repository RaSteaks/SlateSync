// ARRI XML 元数据来源：官方 FCP 7 XML 侧车（单片段一个文件）。detect 用显式
// 格式指纹而不是 "扩展名 + 泛匹配"：FCP XML 标记（xmeml/clipitem/DOCTYPE
// plist）与 ARRI 字段标记（Sensor_fps/filmslate/mastercomment/column= 的
// <field>）必须同时出现——先查 2KB 头部作快路径，未命中时全文复查（FCP XML
// 允许在首个 clipitem 前放很长的 sequence/format 段，文件体积已在上游按
// maxSlateBytes 封顶，全文指纹不会放大读取）；ACES AMF 显式排除（AMF 通常
// 指 ACES Metadata File，不是相机素材元数据）。MXF metadata XML 的指纹待
// 真实样本校准（TODO-calibration）。
// 解析走 parseLooseXmlElementIndex 的三形态索引（value 属性对 / 叶子文本 /
// 嵌入 Key: value 行），fps 走 normalizeArriFps（×1000 编码与有理数）；候选表
// 刻意不含 projectfps——项目时基不是传感器帧率。归属校验与单片段载体一致：
// Clip Name 与文件名素材键并存且不一致 → 抛错，两者皆无 → 抛错。
import {
  canonicalKeyToMaterialPrefix,
  extractCombinedMaterialKey,
  normalizeShootDay,
} from "../metadata-common.js";
import {
  buildArriExtra,
  decodeArriHeadText,
  decodeArriText,
  displaySourceName,
  fileNameOf,
  firstNormalizableValue,
  makeArriEntry,
  normalizeArriFps,
  normalizeIndexKey,
  parseLooseXmlElementIndex,
} from "./arri-common.js";

const XML_FILE_PATTERN = /\.xml$/i;
// 指纹扫描范围：BOM/UTF-16 头部解码后取前 2KB
const HEAD_BYTES = 2048;

// ACES Metadata File：根元素 <amf> / 带前缀 <aces:amf> / URN 命名空间
const ACES_AMF_PATTERN = /<(?:[\w-]+:)?amf[\s/>]|urn:asc:amf/i;
const FCP_MARKER_PATTERN = /xmeml|clipitem|<!DOCTYPE\s+plist/i;
const ARRI_MARKER_PATTERN =
  /sensor[\s_-]*fps|filmslate|mastercomment|<field[\s>][^>]*column\s*=/i;

// 候选键（经 normalizeIndexKey 归一后匹配，大小写/下划线/空格不敏感）
const FPS_KEY_CANDIDATES = ["sensor_fps", "sensorfps", "capturefps", "framerate"];
const DATE_KEY_CANDIDATES = ["recordingdate", "shootdate", "fieldday", "date"];
const CLIP_KEY_CANDIDATES = ["name", "clipname", "masterclipid"];
const identity = (value) => value;

export const arriXmlMetadataSource = {
  id: "arri-xml",
  label: "ARRI XML（FCP 7）",
  filePatterns: [XML_FILE_PATTERN],
  detect(sourceName, input) {
    if (!XML_FILE_PATTERN.test(String(sourceName || ""))) return false;
    const head = decodeArriHeadText(input, HEAD_BYTES);
    if (!head || ACES_AMF_PATTERN.test(head)) return false;
    if (FCP_MARKER_PATTERN.test(head) && ARRI_MARKER_PATTERN.test(head)) return true;
    // 头部指纹未命中 → 全文指纹复查：长 sequence/format 段可能把首个
    // clipitem/ARRI 字段推出 2KB 头部。普通 FCP XML（无 ARRI 标记）与
    // AMF 依旧不命中，已接受的文件集合不变。
    const full = decodeArriHeadText(input, Infinity);
    return FCP_MARKER_PATTERN.test(full) && ARRI_MARKER_PATTERN.test(full);
  },
  parse(input, sourceName) {
    return parseArriXmlText(input, sourceName);
  },
};

export function parseArriXmlText(input, sourceName = "") {
  const label = displaySourceName(sourceName);
  const index = parseLooseXmlElementIndex(decodeArriText(input, sourceName));

  const { clipName, materialKey } = resolveMaterial(index, sourceName);
  const sensorFps = firstNormalizableValue(index, FPS_KEY_CANDIDATES, normalizeArriFps);
  const shootDay = firstNormalizableValue(index, DATE_KEY_CANDIDATES, normalizeShootDay);
  if (!sensorFps && !shootDay) {
    throw new Error(`${label} 缺少有效的帧率或拍摄日期`);
  }

  return makeArriEntry({
    sourceName: label,
    clipName,
    materialKey,
    sensorFps,
    shootDay,
    extra: buildArriExtra((candidates) =>
      firstNormalizableValue(index, candidates, identity),
    ),
  });
}

// 素材归属：文件名素材键与 XML 内的 Clip Name 键并存时必须一致。
// 头部 <name> 槽位在 FCP XML 里承载序列名/片段名等多种值，只认能解析出素材
// 键的值；存在候选但全部无法识别 → 抛错（单片段载体不静默回退）。
function resolveMaterial(index, sourceName) {
  const label = displaySourceName(sourceName);
  const fileKey = extractCombinedMaterialKey(fileNameOf(sourceName));

  const candidates = [];
  for (const key of CLIP_KEY_CANDIDATES) {
    for (const value of index.get(normalizeIndexKey(key)) || []) {
      if (!candidates.includes(value)) candidates.push(value);
    }
  }

  for (const value of candidates) {
    const clipKey = extractCombinedMaterialKey(value);
    if (!clipKey) continue;
    if (fileKey && clipKey !== fileKey) {
      throw new Error(
        `${label} 的 Clip Name“${value}”与文件名指向不同素材（${clipKey} ≠ ${fileKey}）。`,
      );
    }
    return { clipName: value, materialKey: clipKey };
  }

  if (candidates.length) {
    // 与 arri-quicktime 同策略：单片段载体的 Clip Name 无法识别时不静默回退文件名
    throw new Error(`${label} 的 Clip Name“${candidates[0]}”无法识别`);
  }
  if (!fileKey) {
    throw new Error(`${label} 缺少可识别的素材标识`);
  }
  return { clipName: canonicalKeyToMaterialPrefix(fileKey), materialKey: fileKey };
}
