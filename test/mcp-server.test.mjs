import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMcpServer } from "../mcp-server.mjs";
import { createTaskLimiter } from "../lib/service/runtime.mjs";

const TOOL_NAMES = [
  "delete_diagnostic_session",
  "delete_task",
  "get_ai_exchange",
  "get_config",
  "get_diagnostic_session",
  "get_ocr_evidence",
  "get_scenario",
  "get_system_prompts",
  "import_scenario",
  "list_diagnostic_sessions",
  "list_models",
  "list_scenarios",
  "list_tasks",
  "load_task",
  "recognize_slate",
  "save_provider_key",
];

// “configured” 状态读取的是 process.env，因此测试先把服务商 Key 从
// process.env 中清掉，结束时再恢复 shell 原有的值。
const PROVIDER_KEY_VARS = [
  "OPENAI_API_KEY",
  "OPENROUTER_API_KEY",
  "TOKENPLAN_API_KEY",
  "DASHSCOPE_API_KEY",
  "OPENAI_COMPATIBLE_API_KEY",
  "PADDLEOCR_ENABLED",
  "PADDLEOCR_REQUIRED",
  "VISIONOCR_ENABLED",
  "VISIONOCR_REQUIRED",
];

/**
 * 在临时数据目录上启动一个进程内 MCP 实例，并用 InMemoryTransport 直连。
 * @param {{ processEnv?: object }} [options] processEnv 会写入 process.env
 *   （如注入测试 Key），close 时恢复
 * @returns {Promise<{ client: object, services: object, close: () => Promise<void> }>}
 *   close 依次断开客户端、关闭 SQLite 连接、恢复环境变量并删除临时目录
 */
async function startMcp({ processEnv = {} } = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-mcp-"));
  await writeFile(
    join(dataDir, "slatesync.config.json"),
    JSON.stringify({
      slate: { maxDirectoryDepth: 4 },
      resolve: { fieldFormats: { scene: "XXX", shot: "XX", take: "XX" } },
    }),
  );

  const savedEnv = new Map();
  for (const key of PROVIDER_KEY_VARS) {
    savedEnv.set(key, process.env[key]);
    delete process.env[key];
  }
  process.env.PADDLEOCR_ENABLED ||= "false";
  process.env.PADDLEOCR_REQUIRED ||= "false";
  process.env.VISIONOCR_ENABLED ||= "false";
  process.env.VISIONOCR_REQUIRED ||= "false";
  for (const [key, value] of Object.entries(processEnv)) {
    process.env[key] = value;
  }

  const mcp = await createMcpServer({
    loadEnvFile: false,
    env: {
      SLATESYNC_CONFIG_PATH: join(dataDir, "slatesync.config.json"),
      SLATESYNC_DATA_DIR: dataDir,
    },
  });
  const client = new Client({ name: "slatesync-test", version: "0.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await mcp.server.connect(serverTransport);
  await client.connect(clientTransport);

  return {
    client,
    services: mcp.services,
    async close() {
      await client.close();
      await mcp.close();
      for (const [key, value] of savedEnv) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      await rm(dataDir, { recursive: true, force: true });
    },
  };
}

test("recognition limiter rejects when the single slot is busy", () => {
  const limiter = createTaskLimiter(1);
  const release = limiter.acquire();
  assert.throws(() => limiter.acquire(), /正在处理 1 个识别任务/);
  release();
  const second = limiter.acquire();
  second();
});

test("MCP exposes the full tool registry over an in-memory transport", async () => {
  const mcp = await startMcp();
  try {
    const { tools } = await mcp.client.listTools();
    assert.deepEqual(tools.map((tool) => tool.name).sort(), TOOL_NAMES);
    for (const tool of tools) {
      assert.ok(tool.description);
      assert.ok(tool.inputSchema);
    }
  } finally {
    await mcp.close();
  }
});

test("get_config matches the Web contract and never leaks keys or pricing", async () => {
  const mcp = await startMcp({
    processEnv: {
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "http://127.0.0.1:1/v1",
    },
  });
  try {
    const result = await mcp.client.callTool({
      name: "get_config",
      arguments: {},
    });
    assert.notEqual(result.isError, true);
    const config = JSON.parse(result.content[0].text);
    assert.equal(typeof config.upload.maxRequestBytes, "number");
    assert.deepEqual(config.scenarios, []);
    assert.equal(
      config.providers.find((provider) => provider.id === "openai").configured,
      true,
    );
    const text = result.content[0].text;
    assert.equal(text.includes("test-key"), false);
    assert.equal(text.includes("price"), false);
  } finally {
    await mcp.close();
  }
});

test("list_models degrades to the static fallback without pricing", async () => {
  const mcp = await startMcp({
    processEnv: {
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "http://127.0.0.1:1/v1",
    },
  });
  try {
    const result = await mcp.client.callTool({
      name: "list_models",
      arguments: { provider: "openai" },
    });
    assert.notEqual(result.isError, true);
    const data = JSON.parse(result.content[0].text);
    assert.equal(data.source, "static-fallback");
    assert.ok(data.warning);
    assert.ok(
      data.models.some((model) => model.id === "openai/gpt-5.6-terra"),
    );
    assert.equal(JSON.stringify(data).includes("price"), false);
  } finally {
    await mcp.close();
  }
});

test("save_provider_key persists and clears runtime keys", async () => {
  const mcp = await startMcp();
  try {
    const saved = await mcp.client.callTool({
      name: "save_provider_key",
      arguments: { provider: "openai", apiKey: "runtime-secret" },
    });
    assert.deepEqual(JSON.parse(saved.content[0].text), {
      provider: "openai",
      configured: true,
    });

    const cleared = await mcp.client.callTool({
      name: "save_provider_key",
      arguments: { provider: "openai", apiKey: "" },
    });
    assert.equal(JSON.parse(cleared.content[0].text).configured, false);

    const unsupported = await mcp.client.callTool({
      name: "save_provider_key",
      arguments: { provider: "openai-compatible", apiKey: "x" },
    });
    assert.equal(unsupported.isError, true);
    assert.match(
      JSON.parse(unsupported.content[0].text).error,
      /OpenAI 兼容 API 需通过环境变量配置/,
    );
  } finally {
    await mcp.close();
  }
});

test("scenario import, fetch, and not-found errors return error results", async () => {
  const mcp = await startMcp();
  try {
    const profile = {
      label: "测试版式",
      layout: {
        pages: [],
        headerTokens: ["场次"],
        cameraGroups: [],
        columnBands: [],
        rowBands: [],
      },
    };
    const imported = await mcp.client.callTool({
      name: "import_scenario",
      arguments: { profile },
    });
    const importedProfile = JSON.parse(imported.content[0].text);
    assert.match(importedProfile.id, /^scenario-[a-f0-9]{16}$/);

    const listed = await mcp.client.callTool({
      name: "list_scenarios",
      arguments: {},
    });
    assert.equal(JSON.parse(listed.content[0].text).length, 1);

    const loaded = await mcp.client.callTool({
      name: "get_scenario",
      arguments: { id: importedProfile.id },
    });
    assert.equal(JSON.parse(loaded.content[0].text).id, importedProfile.id);

    const missing = await mcp.client.callTool({
      name: "get_scenario",
      arguments: { id: "scenario-0000000000000000" },
    });
    assert.equal(missing.isError, true);
    assert.match(
      JSON.parse(missing.content[0].text).error,
      /场记结构不存在/,
    );

    const unknown = await mcp.client.callTool({
      name: "no_such_tool",
      arguments: {},
    });
    assert.equal(unknown.isError, true);
    assert.match(JSON.parse(unknown.content[0].text).error, /未知的工具/);
  } finally {
    await mcp.close();
  }
});

test("task store wiring is visible through list_tasks, load_task, delete_task", async () => {
  const mcp = await startMcp();
  try {
    const taskId = await mcp.services.taskStore.saveTask({
      status: "completed",
      filename: "day-01.pdf",
      pageCount: 1,
      provider: "openai",
      model: "openai/gpt-5.6-terra",
      result: { records: [{ id: "one" }] },
    });

    const listed = await mcp.client.callTool({
      name: "list_tasks",
      arguments: {},
    });
    const tasks = JSON.parse(listed.content[0].text);
    assert.equal(tasks.length, 1);
    assert.equal(tasks[0].id, taskId);
    assert.equal(tasks[0].recordCount, 1);
    assert.equal(tasks[0].filename, "day-01.pdf");

    const loaded = await mcp.client.callTool({
      name: "load_task",
      arguments: { id: taskId },
    });
    assert.equal(JSON.parse(loaded.content[0].text).filename, "day-01.pdf");

    const deleted = await mcp.client.callTool({
      name: "delete_task",
      arguments: { id: taskId },
    });
    assert.deepEqual(JSON.parse(deleted.content[0].text), { deleted: taskId });

    const missing = await mcp.client.callTool({
      name: "load_task",
      arguments: { id: "no-such-task" },
    });
    assert.equal(missing.isError, true);
    assert.match(JSON.parse(missing.content[0].text).error, /任务不存在/);
  } finally {
    await mcp.close();
  }
});

test("recognize_slate failures surface as error results with a diagnostic session", async () => {
  const mcp = await startMcp();
  try {
    const result = await mcp.client.callTool({
      name: "recognize_slate",
      arguments: {
        provider: "no-such-provider",
        model: "any",
        imageDataGroups: [["data:image/png;base64,AAA"]],
      },
    });
    assert.equal(result.isError, true);
    assert.match(
      JSON.parse(result.content[0].text).error,
      /识别失败（诊断会话/,
    );

    const sessions = await mcp.client.callTool({
      name: "list_diagnostic_sessions",
      arguments: {},
    });
    assert.equal(JSON.parse(sessions.content[0].text).length, 1);
  } finally {
    await mcp.close();
  }
});

test("get_system_prompts returns the recognition prompt set", async () => {
  const mcp = await startMcp();
  try {
    const result = await mcp.client.callTool({
      name: "get_system_prompts",
      arguments: {},
    });
    const prompts = JSON.parse(result.content[0].text);
    assert.ok(prompts.SYSTEM_PROMPT.length > 0);
    assert.ok(prompts.CORE_AUDIT_SYSTEM_PROMPT.length > 0);
    assert.ok(prompts.CORE_REVIEW_SYSTEM_PROMPT.length > 0);
  } finally {
    await mcp.close();
  }
});
