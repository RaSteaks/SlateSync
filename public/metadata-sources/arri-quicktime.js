// QuickTime 内嵌元数据来源（ARRI）：ALEXA 系列把相机/场记信息写进 moov/meta 的
// mdta 键值区，键名形如 com.arri.camera.SensorFps、com.arri.slate.Take。
// 帧率优先容器推导（mdhd.timescale + stts，与 DJI 适配器同一策略），无视频轨时
// 回退 com.arri.* 帧率键（×1000 编码或有理数，见 normalizeArriFps）；拍摄日期
// 优先 mvhd.creationTime，回退 shootDate 类键。ARRI 部分键值是 typed 整数载荷
// 而非文本，走 rawMdtaEntries 的整数解码。
// 输入是调用方（Electron 主进程扫描器）定位好的完整 moov atom 字节，本模块
// 保持纯函数：不做任何文件 I/O，渲染端与 CSV Worker 也可安全导入。
import {
  canonicalKeyToMaterialPrefix,
  extractCombinedMaterialKey,
  normalizeCameraFps,
  normalizeShootDay,
} from "../metadata-common.js";
import {
  buildArriExtra,
  displaySourceName,
  fileNameOf,
  hasArriQuickTimeMarker,
  makeArriEntry,
  normalizeArriFps,
  normalizeIndexKey,
} from "./arri-common.js";
import {
  QUICKTIME_FILE_PATTERN,
  formatCreationDate,
  formatFps,
  walkQuickTimeMoov,
} from "./quicktime.js";

// 帧率/日期键取 com.arri. 前缀的末段归一化后匹配（camera.SensorFps → sensorfps）。
// 刻意不含 projectfps/projectframerate：项目时基不是传感器帧率。
const FPS_KEY_CANDIDATES = [
  "sensorfps",
  "capturefps",
  "captureframerate",
  "sensorframerate",
  "camerafps",
  "framerate",
];
const DATE_KEY_CANDIDATES = ["shootdate", "recordingdate", "shootingdate"];
const CLIP_KEY_CANDIDATES = ["clipname", "clipfilename", "name"];

export const arriQuicktimeMetadataSource = {
  id: "arri-quicktime",
  label: "ARRI QuickTime 内嵌元数据",
  filePatterns: [QUICKTIME_FILE_PATTERN],
  detect(sourceName, input) {
    return (
      QUICKTIME_FILE_PATTERN.test(String(sourceName || "")) &&
      hasArriQuickTimeMarker(input)
    );
  },
  parse(input, sourceName) {
    return parseArriQuickTimeMoov(input, sourceName);
  },
};

// 解析完整 moov atom（含 8 字节 size/type 头），输出与其他来源一致的规范形状：
// { sourceName, clipName, materialKey, sensorFps, shootDay[, extra] }。
export function parseArriQuickTimeMoov(input, sourceName = "") {
  const parsed = walkQuickTimeMoov(input);
  if (!parsed) {
    throw new Error(
      `${displaySourceName(sourceName)} 缺少 moov atom，无法读取内嵌元数据`,
    );
  }
  const arriValue = arriValueReader(parsed.rawMdtaEntries);

  const clipName = arriValue(CLIP_KEY_CANDIDATES);
  const clipKey = extractCombinedMaterialKey(clipName);
  // 文件名兜底：ARRI MOV 的素材键以文件名为准（com.arri.* 内的键缺失时）。
  const sourceKey = extractCombinedMaterialKey(fileNameOf(sourceName));
  if (clipName && !clipKey) {
    throw new Error(
      `${displaySourceName(sourceName)} 的 Clip Name“${clipName}”无法识别`,
    );
  }
  if (clipKey && sourceKey && clipKey !== sourceKey) {
    throw new Error(
      `${displaySourceName(sourceName)} 的 Clip Name“${clipName}”与文件名指向不同素材`,
    );
  }
  const materialKey = clipKey || sourceKey;
  if (!materialKey) {
    throw new Error(`${displaySourceName(sourceName)} 缺少可识别的素材标识`);
  }

  const sensorFps =
    normalizeCameraFps(formatFps(parsed.videoTrack)) ||
    normalizeArriFps(arriValue(FPS_KEY_CANDIDATES));
  const shootDay =
    normalizeShootDay(formatCreationDate(parsed.creationSeconds)) ||
    normalizeShootDay(arriValue(DATE_KEY_CANDIDATES));
  if (!sensorFps && !shootDay) {
    throw new Error(
      `${displaySourceName(sourceName)} 缺少有效的帧率或拍摄日期`,
    );
  }

  return makeArriEntry({
    sourceName: String(sourceName || "(内嵌元数据)"),
    clipName: clipName || canonicalKeyToMaterialPrefix(materialKey),
    materialKey,
    sensorFps,
    shootDay,
    extra: buildArriExtra(arriValue),
  });
}

// com.arri.* 键值读取器：候选末段按顺序匹配；文本优先，typed 数值载荷解码兜底。
function arriValueReader(rawMdtaEntries) {
  const entries = [];
  for (const entry of rawMdtaEntries) {
    const key = String(entry.key || "");
    if (!key.toLowerCase().startsWith("com.arri.")) continue;
    entries.push({
      suffix: normalizeIndexKey(key.split(".").pop()),
      text: entry.text,
      payload: entry.payload,
      typeFlags: entry.typeFlags,
    });
  }
  return (candidates) => {
    for (const candidate of candidates) {
      for (const entry of entries) {
        if (entry.suffix !== candidate) continue;
        const value = entry.text ?? decodeNumericPayload(entry);
        if (value) return value;
      }
    }
    return "";
  };
}

// typeFlags 21/22 为整数、23/24 为 float32/64（QuickTime well-known 类型），
// 大端解码；浮点按 3 位小数对齐（与 formatFps 策略一致）。其余类型不猜。
function decodeNumericPayload(entry) {
  const { typeFlags, payload } = entry;
  if (!payload?.length) return "";
  if (typeFlags === 21 || typeFlags === 22) {
    if (payload.length > 8) return "";
    let value = 0n;
    for (const byte of payload) value = (value << 8n) | BigInt(byte);
    return String(value);
  }
  if (typeFlags === 23 && payload.length === 4) {
    return String(roundPayloadFps(new DataView(payload.buffer, payload.byteOffset).getFloat32(0)));
  }
  if (typeFlags === 24 && payload.length === 8) {
    return String(roundPayloadFps(new DataView(payload.buffer, payload.byteOffset).getFloat64(0)));
  }
  return "";
}

function roundPayloadFps(value) {
  return Number.isFinite(value) ? Math.round(value * 1000) / 1000 : NaN;
}
