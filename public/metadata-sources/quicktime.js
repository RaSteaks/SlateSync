// QuickTime 内嵌元数据来源：DJI 如影 4D 等摄影机把素材标识与拍摄信息直接写进
// MOV/MP4 容器，而不是生成 slate.txt 侧车。解析所需数据全部位于 moov atom：
//   - moov/meta（mdta 键值区）→ com.apple.proapps.clipFileName / reel / cameraName
//   - 视频轨 mdhd.timescale + stts 采样增量 → 推导拍摄帧率（如 24000/1000 = 24）
//   - mvhd.creationTime（Mac 纪元 1904 起的秒）→ 按本地时区换算拍摄日期，
//     与素材命名中的日期段（D020C0016_260906_…）一致
// 输入是调用方（Electron 主进程扫描器）定位好的完整 moov atom 字节，本模块
// 保持纯函数：不做任何文件 I/O，渲染端与 CSV Worker 也可安全导入。
import {
  canonicalKeyToMaterialPrefix,
  cleanValue,
  extractCombinedMaterialKey,
  normalizeCameraFps,
  normalizeShootDay,
} from "../metadata-common.js";

// 视频扩展名只作为"发现候选"的过滤条件；是否真的内嵌可用元数据由 moov 结构校验决定。
export const QUICKTIME_FILE_PATTERN = /\.(?:mov|mp4|m4v)$/i;

// Mac 纪元（1904-01-01）与 Unix 纪元（1970-01-01）之间的固定秒差。
const MAC_EPOCH_OFFSET_SECONDS = 2082844800;

// 帧率按 3 位小数对齐：24000/1001 → 23.976、30000/1001 → 29.97，
// 与 slate.txt 侧车中人工书写的帧率精度保持一致（24 仍输出 "24"）。
const FPS_DECIMALS = 3;

export const quicktimeMetadataSource = {
  id: "quicktime",
  label: "QuickTime 内嵌元数据",
  filePatterns: [QUICKTIME_FILE_PATTERN],
  parse(input, sourceName) {
    return parseQuickTimeMoov(input, sourceName);
  },
};

// 解析完整 moov atom（含 8 字节 size/type 头），输出与其他来源一致的规范形状：
// { sourceName, clipName, materialKey, sensorFps, shootDay }。
export function parseQuickTimeMoov(input, sourceName = "") {
  const bytes = toUint8Array(input);
  if (!bytes || bytes.length < 8 || readAtomType(bytes, 4) !== "moov") {
    throw new Error(
      `${displaySourceName(sourceName)} 缺少 moov atom，无法读取内嵌元数据`,
    );
  }

  const parsed = {
    creationSeconds: null,
    videoTrack: null,
    mdtaKeys: new Map(),
  };
  for (const child of walkChildren(bytes, 8, bytes.length)) {
    if (child.type === "mvhd") parseMvhd(bytes, child, parsed);
    else if (child.type === "trak") parseTrak(bytes, child, parsed);
    else if (child.type === "udta" || child.type === "meta") {
      parseMetaContainer(bytes, child, parsed);
    }
  }

  const proapps = (key) => cleanValue(parsed.mdtaKeys.get(`com.apple.proapps.${key}`));
  const clipFileName = proapps("clipFileName");
  const clipKey = extractCombinedMaterialKey(clipFileName);
  // 文件名兜底：即使摄影机没写 proapps 键（普通 MP4 等），文件名通常仍带素材键。
  const sourceKey = extractCombinedMaterialKey(fileNameOf(sourceName));
  if (clipFileName && !clipKey) {
    throw new Error(
      `${displaySourceName(sourceName)} 的 clipFileName“${clipFileName}”无法识别`,
    );
  }
  if (clipKey && sourceKey && clipKey !== sourceKey) {
    throw new Error(
      `${displaySourceName(sourceName)} 的 clipFileName“${clipFileName}”与文件名指向不同素材`,
    );
  }
  const materialKey = clipKey || sourceKey;
  if (!materialKey) {
    throw new Error(`${displaySourceName(sourceName)} 缺少可识别的素材标识`);
  }

  const sensorFps = normalizeCameraFps(formatFps(parsed.videoTrack));
  const shootDay = normalizeShootDay(formatCreationDate(parsed.creationSeconds));
  if (!sensorFps && !shootDay) {
    throw new Error(
      `${displaySourceName(sourceName)} 缺少有效的帧率或创建时间，无法读取内嵌元数据`,
    );
  }

  return {
    sourceName: String(sourceName || "(内嵌元数据)"),
    clipName: clipFileName || canonicalKeyToMaterialPrefix(materialKey),
    materialKey,
    sensorFps,
    shootDay,
  };
}

// ---- 以下为 MOV/MP4 atom 结构的只读遍历与字段提取 ----

// 逐个产出 [start, end) 区间内的子 atom。yield 的 offset 指向 size 字段。
function* walkChildren(bytes, start, end) {
  let offset = start;
  while (offset + 8 <= end) {
    let size = readU32(bytes, offset);
    const type = readAtomType(bytes, offset + 4);
    let headerSize = 8;
    if (size === 1) {
      // 64 位扩展长度（largesize）
      size = readU64(bytes, offset + 8);
      headerSize = 16;
    } else if (size === 0) {
      // size=0 表示该 atom 延伸到父容器末尾
      size = end - offset;
    }
    if (size < headerSize || offset + size > end) return;
    yield { type, offset, size, headerSize };
    offset += size;
  }
}

// meta atom 的子项前可能带 4 字节 version/flags（iTunes 风格），也可能不带
// （QuickTime 风格）。对 +8/+12 两个候选起点各试解析一次：合法起点必须能
// 自洽地遍历到容器末尾；带 flags 的写法其 flags 值几乎总为 0（读出 size<8），
// 仅当两种起点都可行时优先按无 flags 解析。
function metaChildrenStart(bytes, start, end) {
  const plausible = (offset) => walkChildrenAreSane(bytes, offset, end);
  if (plausible(start)) return start;
  if (start + 4 <= end && plausible(start + 4)) return start + 4;
  // 无法判定时按带 version/flags 处理：malformed 输入由 keys/ilst 缺失兜底
  return start + 4;
}

// 从 offset 起按子 atom 链遍历，检验能否恰好走完 [offset, end) 且无非法 size。
function walkChildrenAreSane(bytes, offset, end) {
  while (offset + 8 <= end) {
    let size = readU32(bytes, offset);
    let headerSize = 8;
    if (size === 1) {
      size = readU64(bytes, offset + 8);
      headerSize = 16;
    } else if (size === 0) {
      size = end - offset;
    }
    if (size < headerSize || offset + size > end) return false;
    offset += size;
  }
  return offset === end;
}

function parseMvhd(bytes, atom, parsed) {
  const payload = atom.offset + atom.headerSize;
  const version = bytes[payload];
  // v0：creation(4)+modification(4)+timescale(4)+duration(4)
  // v1：creation(8)+modification(8)+timescale(4)+duration(8)
  const creation = version === 1
    ? readU64(bytes, payload + 4)
    : readU32(bytes, payload + 4);
  if (creation > 0) parsed.creationSeconds = creation;
}

// 找第一个视频轨（hdlr handler_type === "vide"），记录 timescale 与 stts。
function parseTrak(bytes, trakAtom, parsed) {
  if (parsed.videoTrack) return;
  const trakEnd = trakAtom.offset + trakAtom.size;
  let isVideo = false;
  let timescale = 0;
  let stts = null;
  for (const media of walkChildren(bytes, trakAtom.offset + trakAtom.headerSize, trakEnd)) {
    if (media.type !== "mdia") continue;
    const mediaEnd = media.offset + media.size;
    for (const child of walkChildren(bytes, media.offset + media.headerSize, mediaEnd)) {
      if (child.type === "hdlr") {
        // hdlr 载荷：version/flags(4)+pre_defined(4)+handler_type(4)
        const handlerOffset = child.offset + child.headerSize + 8;
        if (handlerOffset + 4 <= child.offset + child.size) {
          isVideo = isVideo || readAtomType(bytes, handlerOffset) === "vide";
        }
      } else if (child.type === "mdhd") {
        timescale = parseMdhdTimescale(bytes, child);
      } else if (child.type === "minf") {
        stts = stts || findStts(bytes, child);
      }
    }
  }
  if (isVideo && timescale > 0 && stts && stts.totalTicks > 0 && stts.totalSamples > 0) {
    parsed.videoTrack = { timescale, ...stts };
  }
}

// mdhd 记录媒体时间轴：v0 timescale 在载荷 +12，v1 在 +20。
function parseMdhdTimescale(bytes, atom) {
  const payload = atom.offset + atom.headerSize;
  const version = bytes[payload];
  return version === 1 ? readU32(bytes, payload + 20) : readU32(bytes, payload + 12);
}

// 在 minf → stbl 里找 stts（time-to-sample），累加加权平均帧率所需的样本数与时钟数。
function findStts(bytes, minfAtom) {
  const minfEnd = minfAtom.offset + minfAtom.size;
  for (const child of walkChildren(bytes, minfAtom.offset + minfAtom.headerSize, minfEnd)) {
    if (child.type !== "stbl") continue;
    const stblEnd = child.offset + child.size;
    for (const leaf of walkChildren(bytes, child.offset + child.headerSize, stblEnd)) {
      if (leaf.type !== "stts") continue;
      const payload = leaf.offset + leaf.headerSize;
      const entryCount = readU32(bytes, payload + 4);
      let totalSamples = 0;
      let totalTicks = 0;
      for (let index = 0; index < entryCount; index += 1) {
        const entry = payload + 8 + index * 8;
        if (entry + 8 > leaf.offset + leaf.size) break;
        totalSamples += readU32(bytes, entry);
        totalTicks += readU32(bytes, entry) * readU32(bytes, entry + 4);
      }
      return { totalSamples, totalTicks };
    }
  }
  return null;
}

// 解析 mdta 键值区。meta 可能直接挂在 moov 下（DJI：moov/meta），也可能嵌在
// udta 内（moov/udta/meta），因此遇到嵌套 meta 时递归进入。
function parseMetaContainer(bytes, atom, parsed) {
  const start = metaChildrenStart(bytes, atom.offset + atom.headerSize, atom.offset + atom.size);
  const end = atom.offset + atom.size;
  let handlerType = "";
  let keysAtom = null;
  let ilstAtom = null;
  for (const child of walkChildren(bytes, start, end)) {
    if (child.type === "meta") {
      // udta → meta 嵌套布局
      parseMetaContainer(bytes, child, parsed);
    } else if (child.type === "hdlr") {
      const handlerOffset = child.offset + child.headerSize + 8;
      if (handlerOffset + 4 <= child.offset + child.size) {
        handlerType = readAtomType(bytes, handlerOffset);
      }
    } else if (child.type === "keys") keysAtom = child;
    else if (child.type === "ilst") ilstAtom = child;
  }
  // 仅 mdta 处理器（QuickTime 专业元数据）提供"完整字符串键 → 值"的映射；
  // iTunes 风格（handler 为 mdir）的 ©xxx 四字符键不在此消费。
  if (handlerType !== "mdta" || !keysAtom || !ilstAtom) return;

  const keyStrings = parseMdtaKeys(bytes, keysAtom);
  const values = parseMdtaIlst(bytes, ilstAtom, keyStrings);
  for (const [key, value] of values) {
    if (!parsed.mdtaKeys.has(key)) parsed.mdtaKeys.set(key, value);
  }
}

// keys 载荷：version/flags(4)+entry_count(4)+N×[size(4)+"mdta"(4)+键名字符串]
function parseMdtaKeys(bytes, atom) {
  const payload = atom.offset + atom.headerSize;
  const end = atom.offset + atom.size;
  const entryCount = readU32(bytes, payload + 4);
  const keys = [];
  let offset = payload + 8;
  for (let index = 0; index < entryCount; index += 1) {
    if (offset + 8 > end) break;
    const size = readU32(bytes, offset);
    if (size < 8 || offset + size > end) break;
    keys.push(text(bytes, offset + 8, offset + size));
    offset += size;
  }
  return keys;
}

// ilst 每项：size(4)+键序号(4)+子 atom（通常为 data：size(4)+"data"(4)+
// type_flags(4)+locale(4)+值载荷）。返回 [键名, 文本值] 列表。
function parseMdtaIlst(bytes, atom, keyStrings) {
  const end = atom.offset + atom.size;
  const values = [];
  for (const item of walkChildren(bytes, atom.offset + atom.headerSize, end)) {
    const keyIndex = readU32(bytes, item.offset + 4);
    const key = keyStrings[keyIndex - 1];
    if (!key) continue;
    const value = readIlstValue(bytes, item);
    if (value != null) values.push([key, value]);
  }
  return values;
}

// 提取 ilst 项里的 data 载荷。仅接受 UTF-8 文本（type_flags=1）或纯可打印字节，
// 二进制值（如 proresraw 白平衡浮点数组）跳过。
function readIlstValue(bytes, item) {
  const itemEnd = item.offset + item.size;
  for (const child of walkChildren(bytes, item.offset + 8, itemEnd)) {
    if (child.type !== "data") continue;
    const payload = child.offset + child.headerSize + 8; // 跳过 type_flags(4)+locale(4)
    const typeFlags = readU32(bytes, child.offset + child.headerSize);
    if (payload >= child.offset + child.size) continue;
    const slice = bytes.subarray(payload, child.offset + child.size);
    // type_flags=1 是 UTF-8 文本；其余类型仅在内容全部可打印时按文本处理
    const printable = [...slice].every((byte) => byte >= 0x20 && byte < 0x7f);
    if (typeFlags !== 1 && !printable) continue;
    const value = text(bytes, payload, child.offset + child.size);
    if (value) return value;
  }
  return null;
}

function formatFps(videoTrack) {
  if (!videoTrack) return "";
  const fps = (videoTrack.totalSamples * videoTrack.timescale) / videoTrack.totalTicks;
  if (!Number.isFinite(fps) || fps <= 0) return "";
  // 3 位小数对齐标准摄影机帧率；整数帧率（24/25/30）不产生小数尾巴
  return String(Math.round(fps * 10 ** FPS_DECIMALS) / 10 ** FPS_DECIMALS);
}

// mvhd 创建时间是 Mac 纪元秒；拍摄日期按"本地时区日期"换算，
// 与剧组按本地日期命名素材（…_260906_…）的习惯一致。
function formatCreationDate(macSeconds) {
  if (macSeconds == null) return "";
  const unixSeconds = macSeconds - MAC_EPOCH_OFFSET_SECONDS;
  if (unixSeconds <= 0) return "";
  const date = new Date(unixSeconds * 1000);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function toUint8Array(input) {
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  return null;
}

function readU32(bytes, offset) {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

function readU64(bytes, offset) {
  let value = 0n;
  for (let index = 0; index < 8; index += 1) {
    value = (value << 8n) | BigInt(bytes[offset + index] ?? 0);
  }
  return Number(value);
}

function readAtomType(bytes, offset) {
  return String.fromCharCode(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]);
}

// 本模块会同时被渲染进程与 CSV Worker 导入，因此统一用 TextDecoder 而非 Node Buffer。
const UTF8_DECODER = new TextDecoder("utf-8");

function text(bytes, start, end) {
  return UTF8_DECODER.decode(bytes.subarray(start, end));
}

function fileNameOf(sourceName) {
  return String(sourceName || "").split(/[\\/]/).filter(Boolean).at(-1) || "";
}

function displaySourceName(sourceName) {
  return String(sourceName || "(未命名)").trim() || "(未命名)";
}
