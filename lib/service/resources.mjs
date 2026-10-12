// Web 与 MCP 共享的场记结构 Profile 与任务操作。
//
// 存储层用 ENOENT 错误码表示“资源不存在”；这里统一转译一次，HTTP 侧得到
// 干净的 404，MCP 侧得到明确的 not-found 错误结果，而不是把底层错误原样
// 暴露出去。非法标识符由存储层抛出（带 400 状态码），同样在此放行。
import { statusError } from "./runtime.mjs";

/**
 * 判断错误是否为“资源不存在”（存储层约定 ENOENT）。
 * @param {Error} error 存储层抛出的错误
 * @returns {boolean}
 */
export function isNotFound(error) {
  return error?.code === "ENOENT";
}

/**
 * 列出全部已学习的场记结构 Profile 摘要。
 * @param {object} services 共享服务集合
 * @returns {Promise<Array<object>>} Profile 摘要数组
 */
export async function listScenarios(services) {
  return services.scenarioStore.listProfiles();
}

/**
 * 按 ID 读取一个场记结构 Profile。
 * @param {object} services 共享服务集合
 * @param {string} id Profile ID
 * @returns {Promise<object>} 完整 Profile
 * @throws {Error} 不存在抛 404；非法 ID 透传存储层的 400
 */
export async function getScenario(services, id) {
  try {
    return await services.scenarioStore.getProfile(id);
  } catch (error) {
    if (isNotFound(error)) throw statusError("场记结构不存在", 404);
    throw error;
  }
}

/**
 * 导入可迁移的场记结构 Profile（相同指纹不会重复创建）。
 * @param {object} services 共享服务集合
 * @param {object} profile 便携 Profile JSON；接受 { profile } 包裹或裸对象
 * @returns {Promise<object>} 导入后的 Profile
 * @throws {Error} 结构非法时标注为 400 客户端错误
 */
export async function importScenario(services, profile) {
  try {
    return await services.scenarioStore.importProfile(profile);
  } catch (error) {
    // 格式错误的便携 Profile 属于客户端问题，而非服务器故障。
    error.status = Number(error.status) || 400;
    throw error;
  }
}

/**
 * 列出识别任务摘要（按更新时间倒序）。
 * @param {object} services 共享服务集合
 * @param {{ limit?: number, offset?: number }} [options] 分页选项；缺省不限量
 * @returns {Promise<Array<object>>} 摘要数组，不含完整识别结果
 */
export async function listTasks(services, options = {}) {
  return services.taskStore.listTasks(options);
}

/**
 * 按 ID 读取识别任务完整数据。
 * @param {object} services 共享服务集合
 * @param {string} id 任务 ID
 * @returns {Promise<object>} 完整任务
 * @throws {Error} 不存在抛 404；非法 ID 透传存储层的 400
 */
export async function loadTask(services, id) {
  try {
    return await services.taskStore.loadTask(id);
  } catch (error) {
    if (isNotFound(error)) throw statusError("任务不存在", 404);
    throw error;
  }
}

/**
 * 增量更新识别任务（与前端自动保存共用）。
 * @param {object} services 共享服务集合
 * @param {string} id 任务 ID
 * @param {object} patch 要合并的字段
 * @returns {Promise<object>} 更新后的完整任务
 * @throws {Error} 不存在抛 404；非法 ID 透传存储层的 400
 */
export async function updateTask(services, id, patch) {
  try {
    return await services.taskStore.updateTask(id, patch);
  } catch (error) {
    if (isNotFound(error)) throw statusError("任务不存在", 404);
    throw error;
  }
}

/**
 * 删除识别任务（SQLite 行 + JSON 快照）。
 * @param {object} services 共享服务集合
 * @param {string} id 任务 ID
 * @returns {Promise<void>}
 * @throws {Error} 不存在抛 404；非法 ID 透传存储层的 400
 */
export async function deleteTask(services, id) {
  try {
    await services.taskStore.deleteTask(id);
  } catch (error) {
    if (isNotFound(error)) throw statusError("任务不存在", 404);
    throw error;
  }
}
