// ARRI 三个元数据载体（FCP 7 XML 侧车 / QuickTime 内嵌 com.arri.* / ALE）共享的
// 纯函数层。只依赖 vendor 中立的 metadata-common.js，不含 I/O，渲染端与 CSV
// Worker 也可安全导入。
//
// extra 扩展契约：ARRI 适配器的 parse 输出可携带可选 extra 对象，键名跨载体统一
//   { scene, take, tcStart, tcEnd, whiteBalance, iso, notes }
// 仅包含非空项、纯字符串。现阶段 merge 层（resolve-csv.js）忽略 extra，
// 为后续把场记板信息接入合并流程预留结构。
import {
  cleanValue,
  detectCsvFormat,
  normalizeCameraFps,
} from "../metadata-common.js";

// 帧率按 3 位小数对齐（与 quicktime.js 的 FPS_DECIMALS 策略一致）：
// 24000/1001 → 23.976、30000/1001 → 29.97
const FPS_DECIMALS = 3;

// ARRI 专属帧率规范化。官方元数据（SensorFps 字段 / com.arri.camera.SensorFps
// 键）使用 ×1000 编码并有有理数形式，都超出 normalizeCameraFps 的格式与上限：
//   "24" → "24"   "24.000" → "24"   "24000" → "24"   "23976" → "23.976"
//   "24000/1001" → "23.976"   "24000/1000" → "24"
// 解码结果统一经 normalizeCameraFps 收口（范围/格式校验）；ProjectFps 之类由
// 各适配器的候选表排除（刻意不含 projectfps）。
export function normalizeArriFps(value) {
  const raw = cleanValue(value);
  if (!raw) return "";

  let text = raw;
  const rational = raw.match(/^(\d{1,6})\s*\/\s*(\d{1,6})$/);
  if (rational) {
    const denominator = Number(rational[2]);
    if (!denominator) return "";
    text = String(roundFps(Number(rational[1]) / denominator));
  } else if (raw.match(/^\d{4,6}(\.\d{1,3})?$/) && Number(raw) > 1000) {
    // ×1000 编码：23976 → 23.976、24000 → 24
    text = String(roundFps(Number(raw) / 1000));
  }
  return normalizeCameraFps(text);
}

function roundFps(fps) {
  if (!Number.isFinite(fps) || fps <= 0) return NaN;
  return Math.round(fps * 10 ** FPS_DECIMALS) / 10 ** FPS_DECIMALS;
}

// 按候选顺序在松散索引中取第一个能被 normalizer 规范化成功的值。
// normalizer 传 (value) => value 即"取首个非空原始值"。
export function firstNormalizableValue(index, candidateKeys, normalizer) {
  for (const key of candidateKeys) {
    for (const value of index.get(normalizeIndexKey(key)) || []) {
      const normalized = normalizer(value);
      if (normalized) return normalized;
    }
  }
  return "";
}

// 索引键归一：小写 + 去空白/下划线/连字符，"Sensor_fps" 与 "Sensor Fps" 同键。
export function normalizeIndexKey(value) {
  return cleanValue(value).toLowerCase().replace(/[\s_-]+/g, "");
}

// 元数据文本解码：BOM/零密度启发（detectCsvFormat）+ 严格解码，失败抛错。
export function decodeArriText(input, label = "") {
  if (typeof input === "string") return stripBom(input);
  const bytes = toUint8Array(input);
  if (!bytes?.length) {
    throw new Error(`${displaySourceName(label)} 的元数据内容为空`);
  }
  const format = detectCsvFormat(bytes);
  try {
    return stripBom(
      new TextDecoder(format.encoding, { fatal: true }).decode(
        bytes.subarray(format.bomBytes),
      ),
    );
  } catch {
    throw new Error(
      `${displaySourceName(label)} 的元数据编码无法识别；仅支持 UTF-8 或 UTF-16 文本。`,
    );
  }
}

// detect 用的头部文本：非严格解码（容忍 UTF-16 截断），只用于指纹扫描。
export function decodeArriHeadText(input, maxBytes = 2048) {
  if (typeof input === "string") return input.slice(0, maxBytes);
  const bytes = toUint8Array(input);
  if (!bytes?.length) return "";
  const head = bytes.subarray(0, Math.min(bytes.length, maxBytes));
  const format = detectCsvFormat(head);
  return new TextDecoder(format.encoding).decode(head.subarray(format.bomBytes));
}

// ---- QuickTime 内容标记（moov 字节里的键名前缀）----

const ARRI_KEY_MARKER = "com.arri.";
const DJI_KEY_MARKER = "com.apple.proapps.";

// mdta keys atom 以完整键名字符串存储，键名前缀必然以字节序列存在于 moov 中。
// 首字节过滤让不匹配区域早退；moov 上限 64MB 内 O(n) 可接受。
export function hasArriQuickTimeMarker(input) {
  return moovBytesContain(input, ARRI_KEY_MARKER);
}

export function hasDjiQuickTimeMarker(input) {
  return moovBytesContain(input, DJI_KEY_MARKER);
}

function moovBytesContain(input, marker) {
  if (typeof input === "string") return input.includes(marker);
  const bytes = toUint8Array(input);
  if (!bytes) return false;
  const first = marker.charCodeAt(0);
  const limit = bytes.length - marker.length;
  outer: for (let offset = 0; offset <= limit; offset += 1) {
    if (bytes[offset] !== first) continue;
    for (let index = 1; index < marker.length; index += 1) {
      if (bytes[offset + index] !== marker.charCodeAt(index)) continue outer;
    }
    return true;
  }
  return false;
}

// ---- ARRI FCP 7 XML 松散索引 ----

// 官方相机 XML 同时用两种形态承载字段值，索引都要收：
//   ① 属性对：<field column="Sensor_fps" value="24000"/>（优先读 value 属性）
//   ② 叶子文本：<name>A001C001_…</name>
//   ③ 嵌入文本行：SensorFps:24.000
// 另有 <SensorFps value="24000"/>（value 属性 + 无 name/column）归到标签名下。
// 返回 Map<归一化键, string[]>，与嵌套层级无关，供候选表查询。
export function parseLooseXmlElementIndex(xmlText) {
  const index = new Map();
  const openTags = [];

  const add = (rawKey, rawValue) => {
    const key = normalizeIndexKey(rawKey);
    const value = cleanValue(rawValue);
    if (!key || !value) return;
    const bucket = index.get(key);
    if (bucket) bucket.push(value);
    else index.set(key, [value]);
  };

  const source = xmlText
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<\?[\s\S]*?\?>/g, " ")
    .replace(/<!DOCTYPE[^>]*>/gi, " ")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, (_match, text) => text);

  const tagPattern = /<(\/?)([A-Za-z_][\w.:-]*)((?:"[^"]*"|'[^']*'|[^"'>])*)(\/?)>/g;
  let cursor = 0;
  let match;
  while ((match = tagPattern.exec(source))) {
    handleText(source.slice(cursor, match.index));
    cursor = tagPattern.lastIndex;

    const [, closing, name, attrText, selfClosing] = match;
    if (closing) {
      openTags.pop();
      continue;
    }
    collectAttributePairs(name, attrText, add);
    if (!selfClosing) openTags.push(name);
  }
  handleText(source.slice(cursor));
  return index;

  function handleText(rawText) {
    const tag = openTags[openTags.length - 1];
    if (!tag || !rawText) return;
    const value = cleanValue(rawText);
    if (value) add(lastTagSegment(tag), value);
    // 嵌入文本形态：SensorFps:24.000（键取首个冒号前，值保留冒号如时码）
    for (const line of rawText.split(/\r\n|\n|\r/)) {
      const pair = line.match(/^\s*([A-Za-z][\w ./-]{0,40}?):\s*(.+?)\s*$/);
      if (pair) add(pair[1], pair[2]);
    }
  }
}

// 形态①/②：name/column 属性值作为键索引 value；只有 value 时归到标签名。
function collectAttributePairs(tagName, attrText, add) {
  const attrs = new Map();
  const pattern = /([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  let match;
  while ((match = pattern.exec(attrText || ""))) {
    attrs.set(normalizeIndexKey(match[1]), match[2] ?? match[3] ?? "");
  }
  const value = attrs.get("value");
  if (value == null) return;
  const nameLike = attrs.get("name") ?? attrs.get("column");
  if (nameLike != null) add(nameLike, value);
  else add(lastTagSegment(tagName), value);
}

function lastTagSegment(tag) {
  return String(tag).split(/[:.]/).pop() || "";
}

// ---- 输出形状与 extra 扩展 ----

// 索引形态载体（XML / QuickTime 键）共用的 extra 候选表；ALE 的列名由适配器
// 自行映射。mastercomment1..4 是 FCP XML 的自由注释槽位，ARRI 对场记字段的
// 具体映射待真实样本校准（TODO-calibration）。
const EXTRA_FIELD_CANDIDATES = [
  ["scene", ["scene", "scenename", "filmslatescene", "slatescene"]],
  ["take", ["take", "slatetake", "filmslatetake"]],
  ["tcStart", ["starttimecode", "starttc", "tcstart"]],
  ["tcEnd", ["endtimecode", "endtc", "tcend"]],
  ["whiteBalance", ["whitebalance", "colortemperature"]],
  ["iso", ["iso", "exposureindex", "ei"]],
  ["notes", ["comments", "mastercomment1", "mastercomment2", "mastercomment3", "mastercomment4"]],
];

// pick(candidates) → 首个非空原始值。仅保留非空项；全部为空返回 null。
export function buildArriExtra(pick, fieldCandidates = EXTRA_FIELD_CANDIDATES) {
  const extra = {};
  for (const [field, candidates] of fieldCandidates) {
    const value = pick(candidates);
    if (value) extra[field] = value;
  }
  return Object.keys(extra).length ? extra : null;
}

// 统一的 canonical 输出形状；extra 仅在非空时挂载。
export function makeArriEntry({
  sourceName,
  clipName,
  materialKey,
  sensorFps,
  shootDay,
  extra,
}) {
  const entry = {
    sourceName: String(sourceName || "(未命名)"),
    clipName,
    materialKey,
    sensorFps,
    shootDay,
  };
  if (extra) entry.extra = extra;
  return entry;
}

// ---- 小工具 ----

export function fileNameOf(sourceName) {
  return String(sourceName || "").split(/[\\/]/).filter(Boolean).at(-1) || "";
}

export function displaySourceName(sourceName) {
  return String(sourceName || "").trim() || "(未命名)";
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function toUint8Array(input) {
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  return null;
}
