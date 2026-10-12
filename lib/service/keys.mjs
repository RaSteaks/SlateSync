// Web 与 MCP 共享的服务商 API Key 持久化。
//
// Key 同时保存在运行时覆盖层（由 createRuntimeEnv 消费）与
// provider-keys.json（重启后仍生效）中。"openai-compatible" 刻意只允许
// 环境变量配置，因为它还需要 Base URL 与模型 ID 两个配套配置。
import { PROVIDERS } from "../config.mjs";
import { statusError } from "./runtime.mjs";

/**
 * 保存或清除一个服务商的运行时 API Key，并持久化到数据目录。
 * @param {object} params
 * @param {string} params.providerId 服务商 ID
 * @param {string} params.apiKey API Key；空字符串表示删除该 Key
 * @param {object} params.keyStore key-store 实例，负责落盘
 * @param {Map<string, string>} params.runtimeProviderKeys 运行时 Key 表（原地修改）
 * @param {{ invalidate: () => void }} [params.runtimeEnv] 运行时环境缓存，变更后置脏
 * @returns {Promise<{ provider: string, configured: boolean }>} 该服务商当前是否可用
 */
export async function saveProviderKey({
  providerId,
  apiKey,
  keyStore,
  runtimeProviderKeys,
  runtimeEnv,
}) {
  const provider = PROVIDERS[providerId];
  if (!provider) {
    throw statusError("未知 API 服务商", 400);
  }
  if (providerId === "openai-compatible") {
    throw statusError("OpenAI 兼容 API 需通过环境变量配置", 400);
  }
  const key = String(apiKey || "").trim();
  if (key) {
    runtimeProviderKeys.set(providerId, key);
  } else {
    runtimeProviderKeys.delete(providerId);
  }
  await keyStore.save(runtimeProviderKeys);
  // Key 变化后使缓存的运行时 env 失效，下一次请求即使用新 Key。
  runtimeEnv?.invalidate();
  return {
    provider: providerId,
    configured: Boolean(
      runtimeProviderKeys.get(providerId) || process.env[provider.envKey],
    ),
  };
}
