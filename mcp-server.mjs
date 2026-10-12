#!/usr/bin/env node
// SlateSync MCP Server — exposes product features and diagnostic data
// via the Model Context Protocol (stdio transport).
//
// Usage:
//   node mcp-server.mjs
//
// The server reads .env from the project root and shares the lib/service/
// wiring with the Web mode; this file owns the MCP transport and tool
// definitions. Tests import createMcpServer() and connect over an in-memory
// transport instead of spawning a process.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { configureModelHttpAgent } from "./lib/ai-client.mjs";
import { createSessionCapture } from "./lib/diagnostics.mjs";
import {
  createRuntimeEnv,
  integerSetting,
  loadLocalEnv,
} from "./lib/service/env.mjs";
import {
  createCachedPublicConfig,
  createSlateServices,
  createTaskLimiter,
} from "./lib/service/runtime.mjs";
import { clientModelDiscovery } from "./lib/service/models.mjs";
import { saveProviderKey } from "./lib/service/keys.mjs";
import {
  clientRecognitionResult,
  persistRecognitionResult,
  recognitionInput,
  runRecognition,
} from "./lib/service/recognition.mjs";
import {
  deleteTask,
  getScenario,
  importScenario,
  listScenarios,
  listTasks,
  loadTask,
} from "./lib/service/resources.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)));

/**
 * 构建 MCP 服务器实例及其共享服务。
 * @param {{ root?: string, env?: object, loadEnvFile?: boolean }} options
 *   root 项目根目录；env 传给服务装配（测试可注入临时数据目录）；
 *   loadEnvFile 为 false 时跳过 .env 读取（测试进程内直连时使用）
 * @returns {Promise<{ server: object, services: object, close: () => Promise<void> }>}
 *   server 为 MCP SDK 实例；close 关闭全部 SQLite 连接
 */
export async function createMcpServer({
  root = ROOT,
  env = process.env,
  loadEnvFile = true,
} = {}) {
  if (loadEnvFile) {
    await loadLocalEnv(join(root, ".env"));
  }
  configureModelHttpAgent(process.env);

  const services = await createSlateServices({ root, env });
  const runtimeProviderKeys = await services.keyStore.load();
  const runtimeEnv = createRuntimeEnv(runtimeProviderKeys);
  services.runtimeEnv = runtimeEnv;
  const publicConfigForRequests = createCachedPublicConfig({
    getWorkflowConfig: services.getWorkflowConfig,
    runtimeEnv,
  });
  const recognitionLimiter = createTaskLimiter(
    integerSetting(
      process.env.MAX_CONCURRENT_RECOGNITIONS,
      1,
      1,
      16,
      "MAX_CONCURRENT_RECOGNITIONS",
    ),
  );

  // --- Tool handlers ---

  // 与 Web /api/config 保持同一契约：补 maxRequestBytes、附带 Profile 列表，
  // 模型价格字段已在 publicConfig 内剥离。
  async function handleGetConfig() {
    const config = await publicConfigForRequests();
    return textResult({
      ...config,
      // Keep the config contract aligned with the Web /api/config response,
      // whose clients size uploads against maxRequestBytes.
      upload: {
        ...config.upload,
        maxRequestBytes: maxBodyBytesSetting(env),
      },
      scenarios: await listScenarios(services),
    });
  }

  async function handleListModels({ provider, refresh }) {
    return textResult(
      await clientModelDiscovery(provider, {
        forceRefresh: Boolean(refresh),
        env: runtimeEnv.get(),
      }),
    );
  }

  async function handleSaveProviderKey({ provider, apiKey }) {
    return textResult(
      await saveProviderKey({
        providerId: provider,
        apiKey,
        keyStore: services.keyStore,
        runtimeProviderKeys,
        runtimeEnv,
      }),
    );
  }

  /**
   * 识别场记单：受并发限流约束；无论成败都保存诊断会话；成功后识别结果
   * 落任务库，与 Web 模式的行为一致。
   * @param {object} params MCP 工具入参（provider/model/imageDataGroups 等）
   * @returns {Promise<object>} MCP 文本结果；失败经 dispatch 转为 isError
   */
  async function handleRecognizeSlate(params) {
    const release = recognitionLimiter.acquire();
    try {
      const capture = createSessionCapture();
      try {
        const input = recognitionInput(
          {
            provider: params.provider,
            model: params.model,
            imageDataGroups: params.imageDataGroups,
            pageCount: params.pageCount || params.imageDataGroups?.length,
            filename: params.filename || "mcp-input",
            accuracyMode: params.accuracyMode || "high",
            scenarioId: params.scenarioId,
            customPrompt: params.customPrompt,
          },
          await services.getWorkflowConfig(),
        );
        const result = await runRecognition(services, input, { capture });
        const { sessionId, taskId } = await persistRecognitionResult(
          services,
          capture.session,
          input,
          result,
        );
        return textResult({
          ...clientRecognitionResult(result),
          diagnosticSessionId: sessionId,
          taskId,
        });
      } catch (error) {
        capture.setError(error);
        // 失败也保留诊断会话，便于 MCP 客户端回溯 OCR 证据与 AI 原始响应；
        // 保存失败不应吞掉原始错误，降级为无会话 ID 的提示。
        const sessionId = await services.diagnostics
          .saveSession(capture.session)
          .catch(() => null);
        throw new Error(
          `识别失败${sessionId ? `（诊断会话 ${sessionId}）` : ""}：${error.message}`,
        );
      }
    } finally {
      release();
    }
  }

  async function handleGetSystemPrompts() {
    const {
      SYSTEM_PROMPT,
      CORE_AUDIT_SYSTEM_PROMPT,
      CORE_REVIEW_SYSTEM_PROMPT,
      PDF_SYSTEM_PROMPT,
    } = await import("./lib/schema.mjs");
    return textResult({
      SYSTEM_PROMPT,
      CORE_AUDIT_SYSTEM_PROMPT,
      CORE_REVIEW_SYSTEM_PROMPT,
      PDF_SYSTEM_PROMPT,
    });
  }

  // --- 工具定义：名称、schema 与 handler 同处一项，
  // --- 新增工具只需向数组追加元素，无需再改分发逻辑。

  const TOOLS = [
    {
      name: "get_config",
      description:
        "获取 SlateSync 当前配置：API 服务商列表、模型列表、OCR 状态、上传限制",
      inputSchema: { type: "object", properties: {} },
      handler: handleGetConfig,
    },
    {
      name: "list_models",
      description:
        "获取指定 API 服务商的可用视觉模型列表。provider 参数：openai、openrouter、tokenplan、dashscope、openai-compatible",
      inputSchema: {
        type: "object",
        properties: {
          provider: { type: "string", description: "API 服务商 ID" },
          refresh: { type: "boolean", description: "强制刷新缓存", default: false },
        },
        required: ["provider"],
      },
      handler: handleListModels,
    },
    {
      name: "save_provider_key",
      description:
        "将 API Key 持久化到 SlateSync 数据目录。provider 参数：openai、openrouter、tokenplan、dashscope",
      inputSchema: {
        type: "object",
        properties: {
          provider: { type: "string", description: "API 服务商 ID" },
          apiKey: { type: "string", description: "API Key（留空清除）" },
        },
        required: ["provider", "apiKey"],
      },
      handler: handleSaveProviderKey,
    },
    {
      name: "recognize_slate",
      description:
        "识别场记单图片。传入 Base64 编码的页面图片组（每页 1-3 张视图），返回结构化识别结果。识别过程中的 OCR 证据和 AI 原始响应会自动保存为诊断会话，识别结果会保存为任务。",
      inputSchema: {
        type: "object",
        properties: {
          provider: { type: "string", description: "API 服务商 ID" },
          model: { type: "string", description: "模型 ID" },
          imageDataGroups: {
            type: "array",
            description: "每页的图片组（Base64 data URL）",
            items: { type: "array", items: { type: "string" } },
          },
          pageCount: { type: "number", description: "页数" },
          filename: { type: "string", description: "来源文件名" },
          scenarioId: {
            type: "string",
            description: "可选的已学习场记结构 Profile ID；留空则自动匹配并学习",
          },
          customPrompt: { type: "string", description: "自定义提示词（可选）" },
          accuracyMode: {
            type: "string",
            enum: ["standard", "high"],
            default: "high",
            description: "识别精度模式",
          },
        },
        required: ["provider", "model", "imageDataGroups"],
      },
      handler: handleRecognizeSlate,
    },
    {
      name: "list_scenarios",
      description: "列出已学习的场记结构 Profile，供识别任务选择和复用",
      inputSchema: { type: "object", properties: {} },
      handler: () => listScenarios(services).then(textResult),
    },
    {
      name: "get_scenario",
      description: "获取一个场记结构 Profile 的完整版式、字段区域和输出配置",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "场记结构 Profile ID" },
        },
        required: ["id"],
      },
      handler: ({ id }) => getScenario(services, id).then(textResult),
    },
    {
      name: "import_scenario",
      description: "导入一个可迁移的场记结构 Profile JSON；相同指纹不会重复创建",
      inputSchema: {
        type: "object",
        properties: {
          profile: { type: "object", description: "场记结构 Profile JSON" },
        },
        required: ["profile"],
      },
      handler: ({ profile }) => importScenario(services, profile).then(textResult),
    },
    {
      name: "list_diagnostic_sessions",
      description:
        "列出所有诊断会话（识别历史记录），包含文件名、模型、记录数等摘要信息",
      inputSchema: { type: "object", properties: {} },
      handler: () => services.diagnostics.listSessions().then(textResult),
    },
    {
      name: "get_diagnostic_session",
      description:
        "获取指定诊断会话的完整数据，包含 OCR 证据、AI 原始请求/响应、最终识别结果。用于分析识别质量和优化提示词。",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "诊断会话 ID" },
        },
        required: ["id"],
      },
      handler: ({ id }) => services.diagnostics.loadSession(id).then(textResult),
    },
    {
      name: "get_ocr_evidence",
      description:
        "获取指定诊断会话中某一页的 OCR 证据数据（文字块、置信度、坐标）",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "诊断会话 ID" },
          page: { type: "number", description: "页码（从 1 开始）" },
        },
        required: ["id", "page"],
      },
      handler: handleGetOcrEvidence,
    },
    {
      name: "get_ai_exchange",
      description:
        "获取指定诊断会话中某一页某个阶段的 AI 请求/响应详情（system prompt、OCR evidence、模型原始输出）",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "诊断会话 ID" },
          page: { type: "number", description: "页码（从 1 开始）" },
          stage: {
            type: "string",
            enum: ["primary", "audit", "review"],
            description: "识别阶段：primary=主识别，audit=查漏，review=复核",
          },
        },
        required: ["id", "page", "stage"],
      },
      handler: handleGetAiExchange,
    },
    {
      name: "delete_diagnostic_session",
      description: "删除指定的诊断会话",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "诊断会话 ID" },
        },
        required: ["id"],
      },
      handler: handleDeleteDiagnosticSession,
    },
    {
      name: "get_system_prompts",
      description:
        "获取当前使用的系统提示词（主识别、查漏、复核），用于分析和优化",
      inputSchema: { type: "object", properties: {} },
      handler: handleGetSystemPrompts,
    },
    {
      name: "list_tasks",
      description: "列出所有识别任务（按任务持久化的完整工作区）",
      inputSchema: { type: "object", properties: {} },
      handler: () => listTasks(services).then(textResult),
    },
    {
      name: "load_task",
      description:
        "加载指定识别任务的完整数据，包含场记单、CSV、OCR 证据、AI 响应、识别结果和用户编辑记录",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "任务 ID" },
        },
        required: ["id"],
      },
      handler: ({ id }) => loadTask(services, id).then(textResult),
    },
    {
      name: "delete_task",
      description: "删除指定的识别任务",
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", description: "任务 ID" },
        },
        required: ["id"],
      },
      handler: handleDeleteTask,
    },
  ];

  const toolIndex = new Map(TOOLS.map((tool) => [tool.name, tool]));

  /**
   * 读取诊断会话中某页的 OCR 证据。
   * 页缺失时以“成功响应内嵌 error 字段”返回——会话本身存在、只是该页
   * 没有数据，属于信息型结果而非工具失败。
   */
  async function handleGetOcrEvidence({ id, page }) {
    const session = await services.diagnostics.loadSession(id);
    const ocrPage = session.ocr?.pages?.find((p) => p.pageNumber === page);
    if (!ocrPage) {
      return textResult({
        error: `会话 ${id} 中没有第 ${page} 页的 OCR 数据`,
        availablePages: (session.ocr?.pages || []).map((p) => p.pageNumber),
      });
    }
    return textResult(ocrPage);
  }

  /** 同 handleGetOcrEvidence：页或阶段缺失时内嵌 error 字段返回。 */
  async function handleGetAiExchange({ id, page, stage }) {
    const session = await services.diagnostics.loadSession(id);
    const pageData = session.pages?.find((p) => p.pageNumber === page);
    if (!pageData) {
      return textResult({
        error: `会话 ${id} 中没有第 ${page} 页的数据`,
        availablePages: (session.pages || []).map((p) => p.pageNumber),
      });
    }
    const stageData = pageData.stages?.find((s) => s.stage === stage);
    if (!stageData) {
      return textResult({
        error: `第 ${page} 页没有 ${stage} 阶段的数据`,
        availableStages: pageData.stages?.map((s) => s.stage),
      });
    }
    return textResult(stageData);
  }

  async function handleDeleteDiagnosticSession({ id }) {
    await services.diagnostics.deleteSession(id);
    return textResult({ deleted: id });
  }

  async function handleDeleteTask({ id }) {
    await deleteTask(services, id);
    return textResult({ deleted: id });
  }

  const server = new Server(
    { name: "slatesync", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map(({ handler, ...definition }) => definition),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    const tool = toolIndex.get(name);
    if (!tool) {
      return errorResult(`未知的工具：${name}`);
    }
    try {
      return await tool.handler(args || {});
    } catch (error) {
      // 工具失败统一转为 isError 结果而非协议级错误，MCP 客户端总能
      // 拿到可读的错误消息，而不是 InternalError。
      return errorResult(error?.message || "工具执行失败");
    }
  });

  return { server, services, close: () => services.close() };
}

/** 把工具结果包装为 MCP 文本内容（JSON 缩进两格，便于人工阅读）。 */
function textResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

/** 把失败包装为 isError 结果，消息放在 JSON 的 error 字段中。 */
function errorResult(message) {
  return {
    isError: true,
    content: [
      { type: "text", text: JSON.stringify({ error: message }, null, 2) },
    ],
  };
}

/** MAX_BODY_MB → 请求体字节上限；与 Web 的 /api/config 契约保持一致。 */
function maxBodyBytesSetting(env) {
  return (
    integerSetting(env.MAX_BODY_MB, 80, 20, 200, "MAX_BODY_MB") * 1024 * 1024
  );
}

// 仅在直接执行本文件时启动 stdio 服务；被测试导入时 createMcpServer
// 不产生任何副作用。
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const mcp = await createMcpServer();
  await mcp.server.connect(new StdioServerTransport());
  console.error("SlateSync MCP Server started");
  // stdin 关闭时释放 SQLite 连接，避免依赖进程退出时的隐式清理。
  mcp.server.onclose = () => {
    mcp.close().catch(() => {});
  };
  for (const signal of ["SIGTERM", "SIGINT"]) {
    process.once(signal, () => {
      mcp.close().finally(() => process.exit(0));
    });
  }
}
