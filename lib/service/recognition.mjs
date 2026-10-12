// Web 与 MCP 共享的识别流程胶水层：请求体映射、recognizeSlate 调用选项、
// 对外结果形态，以及识别完成后的统一落库契约（诊断会话 + 任务行）。
import { recognizeSlate } from "../ai-client.mjs";

/**
 * 把 Web/MCP 的请求体映射为 recognizeSlate 的输入。
 * @param {object} body 入口层收到的原始请求体
 * @param {object} workflowConfig 热加载的工作流配置，提供场/镜/次位宽与条次标记
 * @returns {object} recognizeSlate 可直接消费的输入对象
 */
export function recognitionInput(body, workflowConfig) {
  return {
    providerId: body.provider,
    modelId: body.model,
    imageDataUrl: body.imageDataUrl,
    imageDataUrls: body.imageDataUrls,
    imageDataGroups: body.imageDataGroups,
    pdfDataUrl: body.pdfDataUrl,
    pageCount: body.pageCount,
    filename: body.filename,
    accuracyMode: body.accuracyMode,
    scenarioId: body.scenarioId,
    customPrompt: body.customPrompt,
    // 空数组与缺失统一归一为 null，下游无需再做空值分支。
    slateCsvRecords: body.slateCsvRecords || null,
    fieldFormats: workflowConfig.resolve.fieldFormats,
    comments: workflowConfig.resolve.comments,
  };
}

/**
 * 以共享服务集合调用 recognizeSlate。
 * @param {object} services createSlateServices 的返回值，需已挂载 runtimeEnv
 * @param {object} input recognitionInput 的结果
 * @param {object} [extras] 追加选项，如 onProgress、capture
 * @returns {Promise<object>} recognizeSlate 的完整识别结果
 */
export async function runRecognition(services, input, extras = {}) {
  return recognizeSlate(input, {
    env: services.runtimeEnv.get(),
    ocrAutoEnable: true,
    scenarioStore: services.scenarioStore,
    ...extras,
  });
}

/**
 * 剥离结果中的成本字段，得到可安全返回客户端的副本。
 * @param {object} result recognizeSlate 的完整结果
 * @returns {object} 不含 cost、usage.cost 的浅拷贝；其余字段原样保留
 */
export function clientRecognitionResult(result) {
  const publicResult = { ...result };
  delete publicResult.cost;
  if (publicResult.usage && typeof publicResult.usage === "object") {
    publicResult.usage = { ...publicResult.usage };
    delete publicResult.usage.cost;
  }
  return publicResult;
}

/**
 * 识别成功后的统一落库：先存诊断会话，再把结果保存为任务行。
 * Web 流式识别与 MCP 识别都走这一份契约，任务列表内容保持一致。
 * @param {object} services 共享服务集合
 * @param {object} session createSessionCapture 采集的诊断会话
 * @param {object} input recognitionInput 的结果（取 filename/customPrompt）
 * @param {object} result recognizeSlate 的完整结果
 * @returns {Promise<{ sessionId: string, taskId: string }>} 两级存储的 ID
 */
export async function persistRecognitionResult(services, session, input, result) {
  const sessionId = await services.diagnostics.saveSession(session);
  const taskId = await services.taskStore.saveTask({
    status: "completed",
    filename: input.filename,
    pageCount: result.pageCount,
    provider: result.provider,
    model: result.model,
    scenarioId: result.scenario?.id || null,
    scenarioMatch: result.scenario?.match || null,
    scenarioFingerprint: result.scenario?.fingerprint || null,
    customPrompt: input.customPrompt || null,
    accuracyMode: result.accuracyMode,
    result: result.result,
    usage: result.usage,
    durationMs: result.durationMs,
    ocrSummary: result.ocr,
    diagnosticSessionId: sessionId,
  });
  return { sessionId, taskId };
}
