#!/usr/bin/env node
// SlateSync MCP Server — exposes product features and diagnostic data
// via the Model Context Protocol (stdio transport).
//
// Usage:
//   node mcp-server.mjs
//
// The server reads .env from the project root and uses the same lib/
// modules as the Web/Electron modes.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";

import { recognizeSlate, configureModelHttpAgent } from "./lib/ai-client.mjs";
import {
  createWorkflowConfigProvider,
  publicConfig,
  PROVIDERS,
} from "./lib/config.mjs";
import {
  discoverVisionModels,
  staticProviderModels,
} from "./lib/model-discovery.mjs";
import {
  createDiagnosticsStore,
  createSessionCapture,
} from "./lib/diagnostics.mjs";
import { createKeyStore } from "./lib/key-store.mjs";
import { createTaskStore } from "./lib/task-store.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname);

// Load .env
await loadLocalEnv(join(ROOT, ".env"));
configureModelHttpAgent(process.env);

const workflowConfigPath = resolve(
  ROOT,
  process.env.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
);
const getWorkflowConfig = createWorkflowConfigProvider(workflowConfigPath);
await getWorkflowConfig();
const dataDir = resolve(
  ROOT,
  String(process.env.SLATESYNC_DATA_DIR || "data").trim() || "data",
);
const diagnostics = createDiagnosticsStore(dataDir);
const taskStore = createTaskStore(dataDir);

// API Keys persisted to the configured Web/MCP data directory.
const keyStore = createKeyStore(dataDir);
const runtimeProviderKeys = await keyStore.load();

function runtimeEnv() {
  const env = { ...process.env };
  for (const [providerId, apiKey] of runtimeProviderKeys) {
    const provider = PROVIDERS[providerId];
    if (provider) env[provider.envKey] = apiKey;
  }
  return env;
}

async function loadLocalEnv(path) {
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

// --- Tool definitions ---

const TOOLS = [
  {
    name: "get_config",
    description:
      "获取 SlateSync 当前配置：API 服务商列表、模型列表、OCR 状态、上传限制",
    inputSchema: { type: "object", properties: {} },
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
  },
  {
    name: "recognize_slate",
    description:
      "识别场记单图片。传入 Base64 编码的页面图片组（每页 1-3 张视图），返回结构化识别结果。识别过程中的 OCR 证据和 AI 原始响应会自动保存为诊断会话。",
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
  },
  {
    name: "list_diagnostic_sessions",
    description:
      "列出所有诊断会话（识别历史记录），包含文件名、模型、记录数等摘要信息",
    inputSchema: { type: "object", properties: {} },
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
  },
  {
    name: "get_system_prompts",
    description:
      "获取当前使用的系统提示词（主识别、查漏、复核），用于分析和优化",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "list_tasks",
    description: "列出所有识别任务（按任务持久化的完整工作区）",
    inputSchema: { type: "object", properties: {} },
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
  },
];

// --- Tool handlers ---

async function handleGetConfig() {
  const config = publicConfig(runtimeEnv(), await getWorkflowConfig(), {
    ocrAutoEnable: true,
  });
  return {
    content: [{ type: "text", text: JSON.stringify(config, null, 2) }],
  };
}

async function handleListModels({ provider, refresh }) {
  try {
    const result = await discoverVisionModels(provider, {
      forceRefresh: Boolean(refresh),
      env: runtimeEnv(),
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  } catch (error) {
    if (Number(error.status) === 400) throw error;
    const fallback = staticProviderModels(provider);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              provider,
              source: "static-fallback",
              warning: error.message,
              models: fallback,
            },
            null,
            2,
          ),
        },
      ],
    };
  }
}

async function handleSaveProviderKey({ provider, apiKey }) {
  const p = PROVIDERS[provider];
  if (!p) throw new Error(`未知 API 服务商: ${provider}`);
  if (provider === "openai-compatible") {
    throw new Error("OpenAI 兼容 API 需通过环境变量配置");
  }
  const key = String(apiKey || "").trim();
  if (key) {
    runtimeProviderKeys.set(provider, key);
  } else {
    runtimeProviderKeys.delete(provider);
  }
  await keyStore.save(runtimeProviderKeys);
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({
          provider,
          configured: Boolean(key || process.env[p.envKey]),
        }),
      },
    ],
  };
}

async function handleRecognizeSlate(params) {
  const capture = createSessionCapture();
  try {
    const result = await recognizeSlate(
      {
        providerId: params.provider,
        modelId: params.model,
        imageDataGroups: params.imageDataGroups,
        pageCount: params.pageCount || params.imageDataGroups.length,
        filename: params.filename || "mcp-input",
        accuracyMode: params.accuracyMode || "high",
        customPrompt: params.customPrompt,
        fieldFormats: (await getWorkflowConfig()).resolve.fieldFormats,
        comments: (await getWorkflowConfig()).resolve.comments,
      },
      {
        env: runtimeEnv(),
        ocrAutoEnable: true,
        capture,
      },
    );

    const sessionId = await diagnostics.saveSession(capture.session);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            { ...result, diagnosticSessionId: sessionId },
            null,
            2,
          ),
        },
      ],
    };
  } catch (error) {
    capture.setError(error);
    const sessionId = await diagnostics.saveSession(capture.session);
    throw new Error(
      `识别失败（诊断会话 ${sessionId}）：${error.message}`,
    );
  }
}

async function handleListDiagnosticSessions() {
  const sessions = await diagnostics.listSessions();
  return {
    content: [{ type: "text", text: JSON.stringify(sessions, null, 2) }],
  };
}

async function handleGetDiagnosticSession({ id }) {
  const session = await diagnostics.loadSession(id);
  return {
    content: [{ type: "text", text: JSON.stringify(session, null, 2) }],
  };
}

async function handleGetOcrEvidence({ id, page }) {
  const session = await diagnostics.loadSession(id);
  const ocrPage = session.ocr?.pages?.find((p) => p.pageNumber === page);
  if (!ocrPage) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: `会话 ${id} 中没有第 ${page} 页的 OCR 数据`,
            availablePages: (session.ocr?.pages || []).map((p) => p.pageNumber),
          }),
        },
      ],
    };
  }
  return {
    content: [{ type: "text", text: JSON.stringify(ocrPage, null, 2) }],
  };
}

async function handleGetAiExchange({ id, page, stage }) {
  const session = await diagnostics.loadSession(id);
  const pageData = session.pages?.find((p) => p.pageNumber === page);
  if (!pageData) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: `会话 ${id} 中没有第 ${page} 页的数据`,
            availablePages: (session.pages || []).map((p) => p.pageNumber),
          }),
        },
      ],
    };
  }
  const stageData = pageData.stages?.find((s) => s.stage === stage);
  if (!stageData) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            error: `第 ${page} 页没有 ${stage} 阶段的数据`,
            availableStages: pageData.stages?.map((s) => s.stage),
          }),
        },
      ],
    };
  }
  return {
    content: [{ type: "text", text: JSON.stringify(stageData, null, 2) }],
  };
}

async function handleDeleteDiagnosticSession({ id }) {
  await diagnostics.deleteSession(id);
  return {
    content: [{ type: "text", text: JSON.stringify({ deleted: id }) }],
  };
}

async function handleGetSystemPrompts() {
  const {
    SYSTEM_PROMPT,
    CORE_AUDIT_SYSTEM_PROMPT,
    CORE_REVIEW_SYSTEM_PROMPT,
    PDF_SYSTEM_PROMPT,
  } = await import("./lib/schema.mjs");
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(
          {
            SYSTEM_PROMPT,
            CORE_AUDIT_SYSTEM_PROMPT,
            CORE_REVIEW_SYSTEM_PROMPT,
            PDF_SYSTEM_PROMPT,
          },
          null,
          2,
        ),
      },
    ],
  };
}

async function handleListTasks() {
  const tasks = await taskStore.listTasks();
  return {
    content: [{ type: "text", text: JSON.stringify(tasks, null, 2) }],
  };
}

async function handleLoadTask({ id }) {
  const task = await taskStore.loadTask(id);
  return {
    content: [{ type: "text", text: JSON.stringify(task, null, 2) }],
  };
}

async function handleDeleteTask({ id }) {
  await taskStore.deleteTask(id);
  return {
    content: [{ type: "text", text: JSON.stringify({ deleted: id }) }],
  };
}

// --- Server setup ---

const server = new Server(
  { name: "slatesync", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "get_config":
      return handleGetConfig();
    case "list_models":
      return handleListModels(args);
    case "save_provider_key":
      return handleSaveProviderKey(args);
    case "recognize_slate":
      return handleRecognizeSlate(args);
    case "list_diagnostic_sessions":
      return handleListDiagnosticSessions();
    case "get_diagnostic_session":
      return handleGetDiagnosticSession(args);
    case "get_ocr_evidence":
      return handleGetOcrEvidence(args);
    case "get_ai_exchange":
      return handleGetAiExchange(args);
    case "delete_diagnostic_session":
      return handleDeleteDiagnosticSession(args);
        case "get_system_prompts":
      return handleGetSystemPrompts();
    case "list_tasks":
      return handleListTasks();
    case "load_task":
      return handleLoadTask(args);
    case "delete_task":
      return handleDeleteTask(args);
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("SlateSync MCP Server started");
