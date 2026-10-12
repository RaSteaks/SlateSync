// Web 与 MCP 共享的视觉模型发现与客户端契约。
//
// 两个入口对“实时模型发现”使用同一套回退策略：400（服务商或请求非法）原样
// 上抛，其余错误降级为内置静态模型列表并附 warning；价格字段一律不出进程。
// 同一服务商的并发发现请求共用一个进行中的 Promise，避免重复请求上游。
import {
  discoverVisionModels,
  staticProviderModels,
} from "../model-discovery.mjs";
import { withoutPricing } from "../config.mjs";

// 缓存键为 `${providerId}:${是否强制刷新}`；finally 中移除，
// 保证失败的请求不会被后续调用复用。
const inflightDiscoveries = new Map();

/**
 * 实时发现指定服务商的视觉模型，并按客户端契约整理结果。
 * @param {string} providerId 服务商 ID
 * @param {{ forceRefresh?: boolean, env?: object }} options
 *   forceRefresh 为 true 时绕过 model-discovery 内部的 TTL 缓存
 * @returns {Promise<object>} 实时结果；上游不可用时降级为静态回退结果
 * @throws {Error} 服务商/请求非法（status 400）时原样上抛，不做降级
 */
export async function clientModelDiscovery(
  providerId,
  { forceRefresh = false, env } = {},
) {
  const key = `${providerId}:${Boolean(forceRefresh)}`;
  const pending = inflightDiscoveries.get(key);
  if (pending) return pending;
  const discovery = (async () => {
    try {
      const result = await discoverVisionModels(providerId, {
        forceRefresh,
        env,
      });
      return { ...result, models: (result.models || []).map(withoutPricing) };
    } catch (error) {
      // 400 表示调用参数有问题，降级列表会掩盖错误，必须原样抛出。
      if (Number(error.status) === 400) throw error;
      return staticModelFallback(providerId, error);
    } finally {
      inflightDiscoveries.delete(key);
    }
  })();
  inflightDiscoveries.set(key, discovery);
  return discovery;
}

/**
 * 构造静态回退响应：内置目录中的模型 + 触发回退的 warning。
 * @param {string} providerId 服务商 ID
 * @param {Error} error 触发回退的原始错误
 * @returns {object} 与实时发现同构的响应对象；availableModelCount 未知置 null
 */
export function staticModelFallback(providerId, error) {
  const fallback = staticProviderModels(providerId);
  return {
    provider: providerId,
    source: "static-fallback",
    refreshedAt: new Date().toISOString(),
    availableModelCount: null,
    visionModelCount: fallback.length,
    fixedModelCount: fallback.length,
    warning: error?.message || "无法读取实时模型列表",
    models: fallback.map(withoutPricing),
  };
}
