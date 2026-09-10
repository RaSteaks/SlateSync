// ALE（Avid Log Exchange）元数据来源：DIT 交接常用的 tab 分隔日志，一个文件
// 覆盖多条片段（Heading 头段 + Column 列头行 + Data 数据行），因此本适配器
// 实现批量接口 parseEntries（entry[]）；单条 parse 抛错指向批量接口，
// parseMetadataFile 绝不静默只取第一行。
// 列名因项目而异，按候选表宽松匹配（归一化：小写去空格/下划线）；无法识别
// 素材键的行静默跳过，全部行都无法识别才抛错；fps/拍摄日期列缺失或不可解析
// 时对应字段输出空串。fps 列走 normalizeArriFps（兼容 "23.976"、×1000 编码
// 与 "24000/1001" 有理数）；日期刻意走 normalizeShootDay 的严格校验，美式
// M/D/YYYY 等歧义顺序被拒绝而不是错读（真实样本若如此需加适配器级转换，
// 见校准清单）。
import {
  cleanValue,
  extractCombinedMaterialKey,
  normalizeShootDay,
} from "../metadata-common.js";
import {
  decodeArriHeadText,
  decodeArriText,
  displaySourceName,
  makeArriEntry,
  normalizeArriFps,
  normalizeIndexKey,
} from "./arri-common.js";

const ALE_FILE_PATTERN = /\.ale$/i;

// 列名候选（归一化后匹配）；刻意不含 projectfps——项目时基不是传感器帧率。
const CLIP_COLUMN_CANDIDATES = ["name", "clip", "clipname"];
const FPS_COLUMN_CANDIDATES = ["fps", "capturefps", "framerate", "speed"];
const DATE_COLUMN_CANDIDATES = ["shootdate", "shootday", "shootingdate", "date"];
const EXTRA_COLUMN_CANDIDATES = [
  ["scene", ["scene", "scenename"]],
  ["take", ["take"]],
  ["tcStart", ["start", "tcstart"]],
  ["tcEnd", ["end", "tcend"]],
  ["whiteBalance", ["whitebalance", "colortemperature"]],
  ["iso", ["iso", "exposureindex", "ei"]],
  ["notes", ["comments", "note", "notes"]],
];

export const arriAleMetadataSource = {
  id: "arri-ale",
  label: "ARRI/Avid ALE",
  filePatterns: [ALE_FILE_PATTERN],
  detect(sourceName, input) {
    if (!ALE_FILE_PATTERN.test(String(sourceName || ""))) return false;
    // 头段指纹：Title/FCM 声明行（"TITLE\t…"、"FCM NONE"、"Title: …" 均可）
    return /(?:^|[\r\n])\s*(?:Title|FCM)[\t :]/i.test(decodeArriHeadText(input, 1024));
  },
  parse(input, sourceName) {
    throw new Error(
      `${displaySourceName(sourceName)} 是多片段 ALE 文件，请使用批量解析接口。`,
    );
  },
  parseEntries(input, sourceName) {
    return parseArriAleText(input, sourceName);
  },
};

export function parseArriAleText(input, sourceName = "") {
  const text = decodeArriText(input, sourceName);
  const lines = text.split(/\r\n|\n|\r/);

  const { row: columnRow, columnIndex } = buildColumnIndex(lines, sourceName);
  const clipColumn = columnIndex(CLIP_COLUMN_CANDIDATES);
  if (clipColumn < 0) {
    throw new Error(`${displaySourceName(sourceName)} 缺少素材名列（Name/Clip）`);
  }
  const fpsColumn = columnIndex(FPS_COLUMN_CANDIDATES);
  const dateColumn = columnIndex(DATE_COLUMN_CANDIDATES);

  const entries = [];
  let unrecognizedRows = 0;
  for (const line of lines.slice(columnRow + 1)) {
    if (!line.trim()) continue;
    const cells = line.split("\t");
    const clipName = cleanValue(cells[clipColumn] ?? "");
    const materialKey = extractCombinedMaterialKey(clipName);
    if (!materialKey) {
      unrecognizedRows += 1;
      continue;
    }

    const extra = {};
    for (const [field, candidates] of EXTRA_COLUMN_CANDIDATES) {
      const index = columnIndex(candidates);
      if (index < 0) continue;
      const value = cleanValue(cells[index] ?? "");
      if (value) extra[field] = value;
    }

    entries.push(
      makeArriEntry({
        sourceName: String(sourceName || "(未命名)"),
        clipName,
        materialKey,
        sensorFps: fpsColumn >= 0 ? normalizeArriFps(cells[fpsColumn] ?? "") : "",
        shootDay: dateColumn >= 0 ? normalizeShootDay(cells[dateColumn] ?? "") : "",
        extra: Object.keys(extra).length ? extra : null,
      }),
    );
  }

  if (!entries.length) {
    const hint = unrecognizedRows ? `（${unrecognizedRows} 行的素材名无法识别）` : "";
    throw new Error(`${displaySourceName(sourceName)} 中没有可识别的素材编号${hint}`);
  }
  return entries;
}

// 列头行定位：返回 { row, columnIndex(candidates) }。
//   ① 首选空行边界——Heading 头段（TITLE/FCM/FIELD_DELIM 等键值行）以空行
//      结束，空行之后第一个含制表符的非空行是列头行；
//   ② 兜底（无空行分隔的紧凑写法）——第一个首列像列名（Name/Clip）的 tab 行。
function buildColumnIndex(lines, sourceName) {
  const row = findColumnRow(lines);
  if (row < 0) {
    throw new Error(`${displaySourceName(sourceName)} 缺少 ALE 列头行（Column）`);
  }
  const columns = lines[row].split("\t").map((column) => normalizeIndexKey(column));
  return {
    row,
    columnIndex(candidates) {
      for (const candidate of candidates) {
        const index = columns.indexOf(normalizeIndexKey(candidate));
        if (index >= 0) return index;
      }
      return -1;
    },
  };
}

function findColumnRow(lines) {
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index].trim()) continue;
    for (let next = index + 1; next < lines.length; next += 1) {
      if (!lines[next].trim()) continue;
      if (lines[next].includes("\t")) return next;
      break;
    }
  }
  return lines.findIndex((line) => {
    const cells = line.split("\t");
    return (
      cells.length >= 2 &&
      CLIP_COLUMN_CANDIDATES.includes(normalizeIndexKey(cells[0]))
    );
  });
}
