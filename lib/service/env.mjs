// Web 与 MCP 两个独立入口共用的环境变量装配层。
//
// 两个入口都会读取项目根目录的 .env、把持久化的服务商 Key 叠加到
// process.env 副本上，并解析同一套数值/文本配置。Electron 的对应实现放在
// electron/env-loader.mjs，因为其应用级默认值不同而保持独立。
import { readFile } from "node:fs/promises";
import { PROVIDERS } from "../config.mjs";

/**
 * 逐行解析 .env 文件并写入 process.env。
 * @param {string} path .env 文件路径；文件不存在时静默跳过
 * @returns {Promise<void>} 解析完成后 resolve；不覆盖 process.env 中已有的变量
 */
export async function loadLocalEnv(path) {
  let contents;
  try {
    contents = await readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    // 以第一个 “=” 切分，值本身可以包含 “=”；separator < 1 覆盖
    // “没有 =” 和 “行首就是 =” 两种非法情况。
    const separator = line.indexOf("=");
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
}

/**
 * 生成叠加了运行时服务商 Key 的环境变量副本。
 * @param {Map<string, string>} runtimeProviderKeys 服务商 ID → API Key
 * @returns {object} process.env 的浅拷贝；Key 覆盖写到各服务商的 envKey 上，
 *   不改动 process.env 本身
 */
export function runtimeEnv(runtimeProviderKeys) {
  const env = { ...process.env };
  for (const [providerId, apiKey] of runtimeProviderKeys) {
    const provider = PROVIDERS[providerId];
    if (provider) env[provider.envKey] = apiKey;
  }
  return env;
}

// 首次调用时构建“运行时 Key 覆盖层”，之后一直复用缓存，直到 Key 表变化。
// publicConfig() 用对象身份判断 env 是否派生自 process.env，因此缓存对象
// 必须在多次调用间保持同一引用，否则 OCR 的 autoEnable 判定会失真。
/**
 * 创建带缓存的运行时环境工厂。
 * @param {Map<string, string>} runtimeProviderKeys 服务商 ID → API Key
 * @returns {{ get: () => object, invalidate: () => void }}
 *   get 返回叠加后的 env；invalidate 供保存/删除 Key 后清空缓存
 */
export function createRuntimeEnv(runtimeProviderKeys) {
  let cache;
  return {
    get() {
      cache ??= runtimeEnv(runtimeProviderKeys);
      return cache;
    },
    invalidate() {
      cache = undefined;
    },
  };
}

/**
 * 解析整数配置项，非法或越界直接抛错（启动期 fail-fast，避免带病运行）。
 * @param {string|undefined} value 环境变量原始值
 * @param {number} fallback 未配置或为空时的默认值
 * @param {number} minimum 允许的最小值
 * @param {number} maximum 允许的最大值
 * @param {string} name 配置项名称，用于错误提示
 * @returns {number} 解析后的整数
 */
export function integerSetting(value, fallback, minimum, maximum, name) {
  if (value == null || String(value).trim() === "") return fallback;
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < minimum || numeric > maximum) {
    throw new Error(`${name} 必须是 ${minimum}–${maximum} 之间的整数`);
  }
  return numeric;
}

/**
 * 读取文本配置项并去除首尾空白。
 * @param {string|undefined} value 环境变量原始值
 * @returns {string} 非字符串输入统一返回空字符串
 */
export function cleanSetting(value) {
  return typeof value === "string" ? value.trim() : "";
}
