// Web 与 MCP 两个入口共享的进程级服务装配层。
//
// createSlateServices() 为一个数据目录构建工作流配置提供器、三个基于
// SQLite 的存储与 Key 存储，server.mjs 与 mcp-server.mjs 因此只需保留
// 传输层代码。Electron 构建保留自己的装配逻辑，因为它把存储绑定到每个
// 项目的独立数据库上。
import { resolve } from "node:path";
import { createWorkflowConfigProvider, publicConfig } from "../config.mjs";
import { createDiagnosticsStore } from "../diagnostics.mjs";
import { createKeyStore } from "../key-store.mjs";
import { createTaskStore } from "../task-store.mjs";
import { createScenarioStore } from "../scenario/store.mjs";
import { cleanSetting } from "./env.mjs";

/**
 * 构造携带 HTTP 状态码的错误，供 publicError 统一映射为响应状态。
 * @param {string} message 对外可见的错误信息
 * @param {number} status HTTP 状态码
 * @returns {Error} 带 status 属性的错误对象
 */
export function statusError(message, status) {
  const error = new Error(message);
  error.status = status;
  return error;
}

/**
 * 把任意错误归一化为对外响应的 { status, message }。
 * @param {Error} error 任意抛出的错误
 * @returns {{ status: number, message: string }}
 *   500 且非服务商错误（providerError）时隐藏内部信息，避免泄露实现细节
 */
export function publicError(error) {
  const status = Number(error?.status) || 500;
  const message =
    status === 500 && !error?.providerError
      ? "服务器处理请求时发生错误"
      : error?.message || "服务器处理请求时发生错误";
  return { status, message };
}

/**
 * 创建固定容量的识别并发限流器。
 * @param {number} limit 最大同时运行的识别任务数
 * @returns {{ limit: number, active: number, acquire: () => () => void }}
 *   acquire 在容量已满时抛 429；成功时返回用于释放槽位的 release 函数
 */
export function createTaskLimiter(limit) {
  let active = 0;
  return {
    limit,
    get active() {
      return active;
    },
    acquire() {
      if (active >= limit) {
        throw statusError(
          `服务器正在处理 ${active} 个识别任务，请稍后重试`,
          429,
        );
      }
      active += 1;
      // released 标记保证重复调用 release 不会把计数减成负数。
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
      };
    },
  };
}

/**
 * 装配一个数据目录下的全部共享服务（每个进程调用一次）。
 * @param {{ root: string, env?: object }} options
 *   root 项目根目录，用于解析配置与数据目录；env 允许测试注入环境变量
 * @returns {Promise<object>} 包含 getWorkflowConfig、diagnostics、taskStore、
 *   scenarioStore、keyStore 与统一 close() 的服务集合
 */
export async function createSlateServices({ root, env = process.env }) {
  const workflowConfigPath = resolve(
    root,
    env.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
  );
  const getWorkflowConfig = createWorkflowConfigProvider(workflowConfigPath);
  // 启动即预热一次配置，文件损坏时立刻失败，与各入口此前的启动行为一致。
  await getWorkflowConfig();
  const dataDir = resolve(root, cleanSetting(env.SLATESYNC_DATA_DIR) || "data");
  const diagnostics = createDiagnosticsStore(dataDir);
  const taskStore = createTaskStore(dataDir);
  const scenarioStore = createScenarioStore(dataDir, {
    // 场记结构匹配时读取最新的 scenario.matching，配合配置热加载。
    matching: async () => (await getWorkflowConfig()).scenario?.matching,
  });
  const keyStore = createKeyStore(dataDir);
  return {
    workflowConfigPath,
    getWorkflowConfig,
    dataDir,
    diagnostics,
    taskStore,
    scenarioStore,
    keyStore,
    // 关闭全部 SQLite 连接；优雅停机时保证 WAL 检查点与文件句柄正常释放。
    async close() {
      await Promise.allSettled([
        diagnostics.close(),
        taskStore.close(),
        scenarioStore.close(),
      ]);
    },
  };
}

/**
 * 为 /readyz 与 /api/config 创建 publicConfig 的记忆化包装。
 * 以 env 与 workflow 的对象身份作缓存键：运行时 Key 变更或
 * slatesync.config.json 热加载都会产生新对象，缓存随之失效。
 * @param {{ getWorkflowConfig: () => Promise<object>, runtimeEnv: object }} deps
 * @returns {() => Promise<object>} 异步返回公共配置对象
 */
export function createCachedPublicConfig({ getWorkflowConfig, runtimeEnv }) {
  let cache = null;
  return async function cachedPublicConfig() {
    const env = runtimeEnv.get();
    const workflow = await getWorkflowConfig();
    if (cache && cache.env === env && cache.workflow === workflow) {
      return cache.config;
    }
    const config = publicConfig(env, workflow, { ocrAutoEnable: true });
    cache = { env, workflow, config };
    return config;
  };
}
