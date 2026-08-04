import test from "node:test";
import assert from "node:assert/strict";
import { recognizeSlate } from "../lib/ai-client.mjs";
import {
  CUSTOM_MODEL_ID,
  MODELS,
  publicConfig,
  resolveModel,
  resolveProvider,
} from "../lib/config.mjs";
import { normalizeTakeStatus } from "../lib/schema.mjs";
import {
  materialKey,
  syntheticProductionDayGroundTruth,
} from "../test-support/synthetic-production-day.mjs";

const imageDataUrl = "data:image/jpeg;base64,ZmFrZS1pbWFnZQ==";
const pdfDataUrl = "data:application/pdf;base64,JVBERi0xLjQK";
const modelResult = {
  sheetTitle: "示例项目 Day 01",
  records: [
    {
      cardNumber: "A001",
      videoCode: "C001",
      scene: "12",
      shot: "2",
      take: "3",
      takeStatus: "过",
      description: "人物进门",
      comments: null,
      shotSize: "中景",
      cameraPosition: "正面",
      confidence: "high",
    },
  ],
  warnings: [],
};

const pdfModelResult = {
  ...modelResult,
  records: modelResult.records.map((record) => ({
    ...record,
    sourcePage: 2,
  })),
};

test("model routing only exposes qwen through OpenRouter", () => {
  assert.equal(resolveModel("openai", "qwen/qwen3.7-flash"), null);
  assert.equal(
    resolveModel("openrouter", "qwen/qwen3.7-flash").apiId,
    "qwen/qwen3.7-flash",
  );
  assert.equal(
    resolveModel("openai", "openai/gpt-5.6-luna").apiId,
    "gpt-5.6-luna",
  );
  assert.equal(
    resolveModel("openai", "openai/gpt-5.6-terra").apiId,
    "gpt-5.6-terra",
  );
  assert.equal(
    resolveModel("openrouter", "openai/gpt-5.6-terra").apiId,
    "openai/gpt-5.6-terra",
  );
});

test("custom OpenAI-compatible routing resolves its configured model and transport", () => {
  const env = {
    OPENAI_COMPATIBLE_API_KEY: "compatible-key",
    OPENAI_COMPATIBLE_BASE_URL: "https://vision.example/v1",
    OPENAI_COMPATIBLE_MODEL: "vendor/vision-ocr",
    OPENAI_COMPATIBLE_API_MODE: "responses",
    OPENAI_COMPATIBLE_JSON_MODE: "prompt",
  };

  assert.equal(resolveProvider("openai-compatible", env).transport, "responses");
  assert.equal(resolveProvider("openai-compatible", env).chatJsonMode, "prompt");
  assert.equal(
    resolveModel("openai-compatible", CUSTOM_MODEL_ID, env).apiId,
    "vendor/vision-ocr",
  );
  assert.equal(resolveModel("openai-compatible", "vendor/vision-ocr", env), null);
});

test("slate symbols normalize into Resolve Comments status values", () => {
  assert.equal(normalizeTakeStatus("☑️"), "过");
  assert.equal(normalizeTakeStatus("√"), "过");
  assert.equal(normalizeTakeStatus("X"), "保");
  assert.equal(normalizeTakeStatus("×"), "保");
  assert.equal(normalizeTakeStatus("三角形"), "废条");
  assert.equal(normalizeTakeStatus("△"), "废条");
  assert.equal(normalizeTakeStatus(""), null);
});

test("public config never exposes API keys", () => {
  const config = publicConfig({
    OPENAI_API_KEY: "secret-openai",
    OPENROUTER_API_KEY: "secret-router",
    OPENAI_COMPATIBLE_API_KEY: "secret-compatible",
    OPENAI_COMPATIBLE_BASE_URL: "https://private-gateway.example/v1",
    OPENAI_COMPATIBLE_MODEL: "private/vision-model",
  });
  assert.equal(config.providers.every((provider) => provider.configured), true);
  assert.equal(JSON.stringify(config).includes("secret-"), false);
  assert.equal(JSON.stringify(config).includes("private-gateway"), false);
  assert.equal(
    config.models.find((model) => model.id === CUSTOM_MODEL_ID).label,
    "private/vision-model",
  );
});

test("provider pricing stays internal and is omitted from public config", () => {
  const luna = MODELS.find(
    (model) => model.id === "openai/gpt-5.6-luna",
  );
  assert.equal(luna.prices.openai, "$1.00 / $6.00 每百万 token");
  assert.match(luna.prices.openrouter, /\$0\.50 \/ \$3\.00/);
  assert.equal(luna.priceUpdatedAt, "2026-07-31");
  const publicLuna = publicConfig({}).models.find(
    (model) => model.id === "openai/gpt-5.6-luna",
  );
  assert.equal("prices" in publicLuna, false);
  assert.equal("pricePerMillion" in publicLuna, false);
  assert.equal("priceUpdatedAt" in publicLuna, false);
});

test("Terra is exposed as a fixed model for OpenAI and OpenRouter", () => {
  const terra = MODELS.find(
    (model) => model.id === "openai/gpt-5.6-terra",
  );
  assert.deepEqual(terra.providers, ["openai", "openrouter"]);
  assert.equal(terra.directId, "gpt-5.6-terra");
  assert.equal(terra.imageDetail, "original");
  assert.equal(terra.prices.openai, "$2.50 / $15.00 每百万 token");
  assert.equal(
    terra.prices.openrouter,
    "$1.25 / $7.50 每百万 token · 当前促销价",
  );
  assert.equal(terra.priceUpdatedAt, "2026-08-03");
  const publicTerra = publicConfig({}).models.find(
    (model) => model.id === "openai/gpt-5.6-terra",
  );
  assert.equal("prices" in publicTerra, false);
});

test("OpenAI Responses request uses image input and parses structured output", async () => {
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request, body: JSON.parse(request.body) };
    return jsonResponse({
      output: [
        {
          type: "message",
          content: [
            { type: "output_text", text: JSON.stringify(modelResult) },
          ],
        },
      ],
      usage: { input_tokens: 120, output_tokens: 80 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "sheet.jpg",
    },
    {
      env: { OPENAI_API_KEY: "test-key" },
      fetchImpl,
    },
  );

  assert.equal(captured.url, "https://api.openai.com/v1/responses");
  assert.equal(captured.body.model, "gpt-4o-mini");
  assert.equal(
    captured.body.input[1].content[1].type,
    "input_image",
  );
  assert.equal(captured.body.input[1].content[1].detail, "high");
  assert.equal(captured.body.text.format.strict, true);
  const recordSchema =
    captured.body.text.format.schema.properties.records.items;
  assert.deepEqual(recordSchema.properties.takeStatus.enum, [
    "过",
    "保",
    "废条",
    null,
  ]);
  assert.equal(recordSchema.properties.goodTake, undefined);
  assert.match(captured.body.input[0].content, /Resolve Comments/);
  assert.match(captured.body.input[0].content, /逐格从上到下复查/);
  assert.match(captured.body.input[0].content, /视频码的数值不代表.*第一条或最后一条/s);
  assert.match(captured.body.input[0].content, /C005.*scene="037".*take="05"/s);
  assert.match(captured.body.input[0].content, /C002.*shot="01".*take="02"/s);
  assert.match(captured.body.input[0].content, /把“次”误读成了“镜”/);
  assert.match(captured.body.input[0].content, /最左侧三个共用列依次是“场次、镜、次”/);
  assert.match(captured.body.input[0].content, /镜 18 输出“18”.*绝不能只读成 08/s);
  assert.match(captured.body.input[0].content, /comments.*绝不写入 Resolve Comments/s);
  assert.equal(result.result.records[0].scene, "012");
  assert.equal(result.result.records[0].shot, "02");
  assert.equal(result.result.records[0].take, "03");
  assert.equal(result.result.records[0].cardNumber, "A001");
  assert.equal(result.result.records[0].takeStatus, "过");
});

test("Qwen uses OpenRouter JSON object mode with the schema in its prompt", async () => {
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request, body: JSON.parse(request.body) };
    return jsonResponse({
      choices: [
        {
          message: {
            content: JSON.stringify(modelResult),
          },
        },
      ],
      usage: {
        prompt_tokens: 200,
        completion_tokens: 100,
        cost: 0.00002,
      },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openrouter",
      modelId: "qwen/qwen3.7-flash",
      imageDataUrl,
      filename: "sheet.jpg",
    },
    {
      env: { OPENROUTER_API_KEY: "test-key" },
      fetchImpl,
    },
  );

  assert.equal(
    captured.url,
    "https://openrouter.ai/api/v1/chat/completions",
  );
  assert.equal(captured.body.model, "qwen/qwen3.7-flash");
  assert.equal(
    captured.body.messages[1].content[1].type,
    "image_url",
  );
  assert.equal(captured.body.response_format.type, "json_object");
  assert.equal(captured.body.provider.require_parameters, true);
  assert.match(captured.body.messages[0].content, /严格遵守以下 Schema/);
  assert.equal(captured.body.response_format.json_schema, undefined);
  assert.equal(result.cost, 0.00002);
});

test("OpenAI-compatible Chat Completions uses custom key, base URL and model without OpenRouter fields", async () => {
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request, body: JSON.parse(request.body) };
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(modelResult) } }],
      usage: { prompt_tokens: 30, completion_tokens: 20 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai-compatible",
      modelId: CUSTOM_MODEL_ID,
      imageDataUrl,
      filename: "compatible.jpg",
    },
    { env: compatibleEnv(), fetchImpl },
  );

  assert.equal(captured.url, "https://vision.example/v1/chat/completions");
  assert.equal(captured.request.headers.Authorization, "Bearer compatible-key");
  assert.equal(captured.request.headers["X-Title"], undefined);
  assert.equal(captured.body.model, "vendor/vision-ocr");
  assert.equal(captured.body.response_format.type, "json_object");
  assert.equal(captured.body.provider, undefined);
  assert.match(captured.body.messages[0].content, /严格遵守以下 Schema/);
  assert.equal(result.provider, "openai-compatible");
  assert.equal(result.model, "vendor/vision-ocr");
  assert.equal(result.result.records[0].videoCode, "C001");
});

test("OpenAI-compatible Responses mode targets the custom /responses endpoint", async () => {
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request, body: JSON.parse(request.body) };
    return jsonResponse({
      output_text: JSON.stringify(modelResult),
      usage: { input_tokens: 30, output_tokens: 20 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai-compatible",
      modelId: CUSTOM_MODEL_ID,
      imageDataUrl,
    },
    {
      env: compatibleEnv({ OPENAI_COMPATIBLE_API_MODE: "responses" }),
      fetchImpl,
    },
  );

  assert.equal(captured.url, "https://vision.example/v1/responses");
  assert.equal(captured.request.headers.Authorization, "Bearer compatible-key");
  assert.equal(captured.body.model, "vendor/vision-ocr");
  assert.equal(captured.body.input[1].content[1].type, "input_image");
  assert.equal(captured.body.text.format.type, "json_schema");
  assert.equal(result.result.records[0].scene, "012");
});

test("OpenAI-compatible Chat Completions can use prompt-only JSON mode", async () => {
  let captured;
  const fetchImpl = async (_url, request) => {
    captured = JSON.parse(request.body);
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(modelResult) } }],
    });
  };

  await recognizeSlate(
    {
      providerId: "openai-compatible",
      modelId: CUSTOM_MODEL_ID,
      imageDataUrl,
    },
    {
      env: compatibleEnv({ OPENAI_COMPATIBLE_JSON_MODE: "prompt" }),
      fetchImpl,
    },
  );

  assert.equal(captured.response_format, undefined);
  assert.equal(captured.provider, undefined);
  assert.match(captured.messages[0].content, /严格遵守以下 Schema/);
});

test("OpenAI-compatible Chat Completions falls back when response_format is unsupported", async () => {
  const requests = [];
  const fetchImpl = async (_url, request) => {
    const body = JSON.parse(request.body);
    requests.push(body);
    if (requests.length === 1) {
      return jsonResponse(
        { error: { message: "response_format is unsupported" } },
        400,
      );
    }
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(modelResult) } }],
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai-compatible",
      modelId: CUSTOM_MODEL_ID,
      imageDataUrl,
    },
    { env: compatibleEnv(), fetchImpl },
  );

  assert.equal(requests.length, 2);
  assert.equal(requests[0].response_format.type, "json_object");
  assert.equal(requests[1].response_format, undefined);
  assert.match(requests[1].messages[0].content, /严格遵守以下 Schema/);
  assert.equal(result.result.records[0].take, "03");
});

test("OpenAI-compatible provider reports missing settings and rejects unsafe base URLs", async () => {
  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openai-compatible",
        modelId: CUSTOM_MODEL_ID,
        imageDataUrl,
      },
      {
        env: compatibleEnv({ OPENAI_COMPATIBLE_BASE_URL: "" }),
        fetchImpl: async () => assert.fail("must not fetch"),
      },
    ),
    /OPENAI_COMPATIBLE_BASE_URL/,
  );

  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openai-compatible",
        modelId: CUSTOM_MODEL_ID,
        imageDataUrl,
      },
      {
        env: compatibleEnv({
          OPENAI_COMPATIBLE_BASE_URL: "https://user:pass@vision.example/v1?token=bad",
        }),
        fetchImpl: async () => assert.fail("must not fetch"),
      },
    ),
    /不能包含账号、密码、查询参数或片段/,
  );
});

test("OpenAI sends a multi-page PDF once as an input_file", async () => {
  const requests = [];
  const fetchImpl = async (url, request) => {
    requests.push({ url, body: JSON.parse(request.body) });
    return jsonResponse({
      output_text: JSON.stringify(pdfModelResult),
      usage: { input_tokens: 90, output_tokens: 30 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-5.6-luna",
      pdfDataUrl,
      pageCount: 5,
      filename: "slate.pdf",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(requests.length, 1);
  const body = requests[0].body;
  assert.equal(body.input[1].content[1].type, "input_file");
  assert.equal(body.input[1].content[1].file_data, pdfDataUrl);
  assert.equal(body.input[1].content[1].detail, "high");
  const recordSchema = body.text.format.schema.properties.records.items;
  assert.equal(recordSchema.properties.sourcePage.type, "integer");
  assert.equal(recordSchema.required.includes("sourcePage"), true);
  assert.match(body.input[0].content, /完整的多页 PDF/);
  assert.match(body.input[0].content, /把该页页码写入 sourcePage/);
  assert.doesNotMatch(
    body.input[0].content,
    /1\. 当前请求只包含场记单的一页/,
  );
  assert.equal(result.inputMode, "pdf");
  assert.equal(result.pageCount, 5);
  assert.equal(result.result.records[0].sourcePage, 2);
});

test("OpenRouter sends PDF binary data through the universal file input", async () => {
  let captured;
  const fetchImpl = async (_url, request) => {
    captured = JSON.parse(request.body);
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(pdfModelResult) } }],
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openrouter",
      modelId: "qwen/qwen3.7-flash",
      pdfDataUrl,
      pageCount: 5,
      filename: "slate.pdf",
    },
    { env: { OPENROUTER_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(captured.messages[1].content[1].type, "file");
  assert.equal(captured.messages[1].content[1].file.filename, "slate.pdf");
  assert.equal(captured.messages[1].content[1].file.file_data, pdfDataUrl);
  assert.equal(captured.response_format.type, "json_object");
  assert.match(captured.messages[0].content, /sourcePage/);
  assert.equal(result.inputMode, "pdf");
  assert.equal(result.result.records[0].sourcePage, 2);
});

test("structured-output OpenRouter models keep strict JSON Schema mode", async () => {
  let captured;
  const fetchImpl = async (_url, request) => {
    captured = JSON.parse(request.body);
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(modelResult) } }],
    });
  };

  await recognizeSlate(
    {
      providerId: "openrouter",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
    },
    { env: { OPENROUTER_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(captured.response_format.type, "json_schema");
  assert.equal(captured.response_format.json_schema.strict, true);
  assert.equal(captured.provider.require_parameters, true);
});

test("OpenRouter retries without native structured outputs when routing rejects parameters", async () => {
  const requests = [];
  const fetchImpl = async (_url, request) => {
    const body = JSON.parse(request.body);
    requests.push(body);
    if (requests.length === 1) {
      return jsonResponse(
        {
          error: {
            message: "No endpoints found that can handle the requested parameters.",
          },
        },
        404,
      );
    }
    return jsonResponse({
      choices: [{ message: { content: JSON.stringify(modelResult) } }],
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openrouter",
      modelId: "openai/gpt-5.6-luna",
      imageDataUrl,
    },
    { env: { OPENROUTER_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(requests.length, 2);
  assert.equal(requests[0].response_format.type, "json_schema");
  assert.equal(requests[1].response_format.type, "json_object");
  assert.match(requests[1].messages[0].content, /严格遵守以下 Schema/);
  assert.equal(result.result.records[0].videoCode, "C001");
});

test("multiple pages are recognized separately and cross-page fields inherit by reel", async () => {
  const captured = [];
  const fetchImpl = async (_url, request) => {
    const body = JSON.parse(request.body);
    captured.push(body);
    const page = captured.length;
    const pageRecords =
      page === 1
        ? [
            {
              ...modelResult.records[0],
              cardNumber: "A001",
              videoCode: "15",
              scene: "39A",
              shot: "5",
              take: "1",
            },
            {
              ...modelResult.records[0],
              cardNumber: "D001",
              videoCode: "05",
              scene: "12",
              shot: "1",
              take: "5",
            },
          ]
        : [
            {
              ...modelResult.records[0],
              cardNumber: "D001",
              videoCode: "06",
              scene: null,
              shot: null,
              take: "6",
            },
          ];
    return jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "测试场记单",
        records: pageRecords,
        warnings: [],
      }),
      usage: { input_tokens: 10, output_tokens: 5 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrls: [imageDataUrl, imageDataUrl],
      filename: "sheet.pdf",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(captured.length, 2);
  for (const request of captured) {
    assert.equal(
      request.input[1].content.filter((part) => part.type === "input_image").length,
      1,
    );
  }
  assert.match(captured[0].input[1].content[0].text, /第 1\/2 页/);
  assert.match(captured[1].input[1].content[0].text, /第 2\/2 页/);
  assert.equal(result.pageCount, 2);
  assert.equal(result.result.records.length, 3);
  assert.deepEqual(
    result.result.records.slice(0, 2).map((record) => record.cardNumber),
    ["A001", "D001"],
  );
  assert.equal(result.result.records[2].cardNumber, "D001");
  assert.equal(result.result.records[2].scene, "012");
  assert.equal(result.result.records[2].shot, "01");
  assert.equal(result.result.records[2].sourcePage, 2);
  assert.match(result.result.warnings.at(-1), /场次、镜.*继承/);
  assert.equal(result.usage.input_tokens, 20);
  assert.equal(result.usage.output_tokens, 10);
});

test("page recognition runs two requests in parallel while preserving page order", async () => {
  let activeRequests = 0;
  let maxActiveRequests = 0;
  let requestCount = 0;
  const fetchImpl = async () => {
    requestCount += 1;
    activeRequests += 1;
    maxActiveRequests = Math.max(maxActiveRequests, activeRequests);
    await new Promise((resolve) => setTimeout(resolve, 5));
    activeRequests -= 1;
    return jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "并发测试",
        records: [],
        warnings: [],
      }),
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrls: Array.from({ length: 5 }, () => imageDataUrl),
      filename: "five-pages.pdf",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(requestCount, 5);
  assert.equal(maxActiveRequests, 2);
  assert.equal(result.pageCount, 5);
  assert.deepEqual(
    result.result.warnings,
    Array.from({ length: 5 }, (_, index) => `第 ${index + 1} 页未识别到任何视频码。`),
  );
});

test("A-camera C006 inherits shot 02 by clip order even when model rows are out of order", async () => {
  const pageRecords = [
    { ...modelResult.records[0], videoCode: "C001", scene: "89A", shot: "1", take: "1" },
    { ...modelResult.records[0], videoCode: "C003", scene: null, shot: null, take: "3" },
    { ...modelResult.records[0], videoCode: "C006", scene: "89A", shot: null, take: "3" },
    { ...modelResult.records[0], videoCode: "C004", scene: "89A", shot: "2", take: "1" },
    { ...modelResult.records[0], videoCode: "C005", scene: null, shot: null, take: "2" },
  ];
  const fetchImpl = async () =>
    jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "89A 场",
        records: pageRecords,
        warnings: [],
      }),
    });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "page-2.jpg",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );
  const c006 = result.result.records.find(
    (record) => record.cardNumber === "A001" && record.videoCode === "C006",
  );

  assert.equal(c006.scene, "089");
  assert.equal(c006.shot, "02");
  assert.equal(c006.take, "03");
  assert.match(result.result.warnings.join("\n"), /C006.*镜.*条号顺序/);
});

test("A-camera C002 inherits merged Shot 01 while keeping row Take 02", async () => {
  const pageRecords = [
    {
      ...modelResult.records[0],
      cardNumber: "A001",
      videoCode: "C001",
      scene: "89A",
      shot: "1",
      take: "1",
    },
    {
      ...modelResult.records[0],
      cardNumber: "A001",
      videoCode: "C002",
      scene: null,
      shot: null,
      take: "2",
    },
  ];
  const fetchImpl = async () =>
    jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "89A 场 01 镜",
        records: pageRecords,
        warnings: [],
      }),
    });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "page-2.jpg",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );
  const c002 = result.result.records.find(
    (record) => record.cardNumber === "A001" && record.videoCode === "C002",
  );

  assert.equal(c002.scene, "089");
  assert.equal(c002.shot, "01");
  assert.equal(c002.take, "02");
  assert.match(result.result.warnings.join("\n"), /C002.*场次、镜.*继承/);
});

test("E-camera C005 inherits merged Scene and Shot from the previous clip", async () => {
  const pageRecords = [
    {
      ...modelResult.records[0],
      cardNumber: "E001",
      videoCode: "C004",
      scene: "37A",
      shot: "1",
      take: "4",
    },
    {
      ...modelResult.records[0],
      cardNumber: "E001",
      videoCode: "C005",
      scene: null,
      shot: null,
      take: "5",
      takeStatus: "过",
    },
  ];
  const fetchImpl = async () =>
    jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "37A 场",
        records: pageRecords,
        warnings: [],
      }),
    });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "page-1.jpg",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );
  const c005 = result.result.records.find(
    (record) => record.cardNumber === "E001" && record.videoCode === "C005",
  );

  assert.equal(c005.scene, "037");
  assert.equal(c005.shot, "01");
  assert.equal(c005.take, "05");
  assert.equal(c005.takeStatus, "过");
  assert.match(result.result.warnings.join("\n"), /C005.*场次、镜.*继承/);
});

test("sequence reconciliation repairs three synthetic field-log digit shifts", async () => {
  const records = [
    { ...modelResult.records[0], cardNumber: "X102", videoCode: "C004", scene: "207", shot: "1", take: "4" },
    { ...modelResult.records[0], cardNumber: "X102", videoCode: "C005", scene: "207", shot: "9", take: "5" },
    { ...modelResult.records[0], cardNumber: "X102", videoCode: "C006", scene: "207", shot: "1", take: "6" },
    { ...modelResult.records[0], cardNumber: "Y201", videoCode: "C031", scene: "142", shot: "14", take: "1" },
    { ...modelResult.records[0], cardNumber: "Y201", videoCode: "C032", scene: "142", shot: "13", take: "6" },
    { ...modelResult.records[0], cardNumber: "Y201", videoCode: "C033", scene: "142", shot: "14", take: "3" },
    { ...modelResult.records[0], cardNumber: "X103", videoCode: "C010", scene: "207", shot: "17", take: "10" },
    { ...modelResult.records[0], cardNumber: "X103", videoCode: "C011", scene: "207", shot: "8", take: "1" },
    { ...modelResult.records[0], cardNumber: "X103", videoCode: "C012", scene: "207", shot: "8", take: "2" },
    { ...modelResult.records[0], cardNumber: "X103", videoCode: "C013", scene: "207", shot: "8", take: "3" },
  ];
  const fetchImpl = async () =>
    jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "示例项目 Day 01",
        records,
        warnings: [],
      }),
    });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      filename: "field-log.jpg",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );
  const byMaterial = new Map(
    result.result.records.map((record) => [
      `${record.cardNumber}${record.videoCode}`,
      record,
    ]),
  );

  assert.deepEqual(
    ["X102C004", "X102C005", "X102C006"].map((key) => [
      byMaterial.get(key).shot,
      byMaterial.get(key).take,
    ]),
    [["01", "04"], ["01", "05"], ["01", "06"]],
  );
  assert.deepEqual(
    ["Y201C031", "Y201C032", "Y201C033"].map((key) => [
      byMaterial.get(key).shot,
      byMaterial.get(key).take,
    ]),
    [["14", "01"], ["14", "02"], ["14", "03"]],
  );
  assert.deepEqual(
    ["X103C011", "X103C012", "X103C013"].map(
      (key) => byMaterial.get(key).shot,
    ),
    ["18", "18", "18"],
  );
  assert.equal(byMaterial.get("X102C005").confidence, "medium");
  assert.match(result.result.warnings.join("\n"), /X102 C005.*09\/05.*01\/05/);
  assert.match(result.result.warnings.join("\n"), /Y201 C032.*13\/06.*14\/02/);
  assert.match(result.result.warnings.join("\n"), /X103 C011–C013.*08.*18/);
});

test("a single out-of-order one-take shot is warned by the model, not auto-renumbered", async () => {
  const fetchImpl = async () =>
    jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "out of order",
        records: [
          { ...modelResult.records[0], cardNumber: "A010", videoCode: "C020", scene: "68", shot: "17", take: "4" },
          { ...modelResult.records[0], cardNumber: "A010", videoCode: "C021", scene: "68", shot: "8", take: "1" },
        ],
        warnings: [],
      }),
    });

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(result.result.records[1].shot, "08");
});

test("high-accuracy multi-view recognition recovers 30 synthetic omissions and reviews 4 synthetic misalignments", async () => {
  const truth = syntheticProductionDayGroundTruth();
  assert.equal(truth.length, 159);

  const omitted = new Set([
    ...materialRange("X101", 1, 15),
    ...materialRange("X102", 1, 5),
    ...materialRange("X102", 9, 15),
    ...materialRange("X102", 56, 58),
  ]);
  assert.equal(omitted.size, 30);

  const wrongValues = new Map([
    ["X103C010", { shot: "07", take: "10" }],
    ["X102C006", { shot: "13", take: "05" }],
    ["X102C007", { shot: "14", take: "01" }],
    ["X102C008", { shot: "14", take: "02" }],
  ]);
  const primaryRecords = truth
    .filter((record) => !omitted.has(materialKey(record)))
    .map((record) => ({
      ...record,
      ...(wrongValues.get(materialKey(record)) || {}),
    }));
  assert.equal(primaryRecords.length, 129);

  const calls = [];
  const fetchImpl = async (_url, request) => {
    const body = JSON.parse(request.body);
    calls.push(body);
    const records =
      calls.length === 1
        ? primaryRecords
        : calls.length === 2
          ? truth
          : truth.filter(
              (record) =>
                wrongValues.has(materialKey(record)) ||
                omitted.has(materialKey(record)),
            );
    return jsonResponse({
      output_text: JSON.stringify({
        sheetTitle: "示例项目 Day 01",
        records,
        warnings: [],
      }),
      usage: { input_tokens: 10, output_tokens: 5 },
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataGroups: [[
        imageDataUrl,
        "data:image/jpeg;base64,dG9wLWRldGFpbA==",
        "data:image/jpeg;base64,Ym90dG9tLWRldGFpbA==",
      ]],
      filename: "示例项目场记单-day-01.pdf",
      accuracyMode: "high",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(calls.length, 3);
  for (const body of calls) {
    assert.equal(
      body.input[1].content.filter((part) => part.type === "input_image").length,
      3,
    );
    assert.match(body.input[1].content[0].text, /同一个来源页/);
  }
  const auditRecordSchema =
    calls[1].text.format.schema.properties.records.items.properties;
  assert.deepEqual(Object.keys(auditRecordSchema).sort(), [
    "cardNumber",
    "confidence",
    "scene",
    "shot",
    "take",
    "takeStatus",
    "videoCode",
  ]);
  assert.match(calls[1].input[0].content, /独立的核心字段完整性复核/);
  for (const key of wrongValues.keys()) {
    assert.match(calls[2].input[1].content[0].text, new RegExp(key));
  }

  assert.equal(result.accuracyMode, "high");
  assert.equal(result.pageCount, 1);
  assert.equal(result.result.records.length, 159);
  assert.equal(result.usage.input_tokens, 30);
  assert.equal(result.usage.output_tokens, 15);
  const actual = new Map(
    result.result.records.map((record) => [materialKey(record), record]),
  );
  for (const expected of truth) {
    const record = actual.get(materialKey(expected));
    assert.ok(record, `missing ${materialKey(expected)}`);
    assert.deepEqual(
      [record.scene, record.shot, record.take],
      [expected.scene, expected.shot, expected.take],
      materialKey(expected),
    );
  }
  assert.equal(
    result.result.warnings.filter((warning) => warning.includes("仅由核心查漏识别到")).length,
    30,
  );
  assert.equal(
    result.result.warnings.filter((warning) => warning.includes("第三次定向复核结果")).length,
    4,
  );
  assert.equal(
    result.result.warnings.filter((warning) => warning.includes("最终定向复核确认存在")).length,
    30,
  );
});

test("an audit-only material is removed when the independent final review cannot confirm it", async () => {
  const base = {
    ...modelResult.records[0],
    cardNumber: "X101",
    videoCode: "C001",
    scene: "142",
    shot: "01",
    take: "01",
  };
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    const records = call === 1 ? [] : call === 2 ? [base] : [];
    return jsonResponse({
      output_text: JSON.stringify({ sheetTitle: null, records, warnings: [] }),
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      accuracyMode: "high",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(call, 3);
  assert.equal(result.result.records.length, 0);
  assert.match(result.result.warnings.join("\n"), /最终定向复核未确认.*已从结果移除/);
});

test("an unresolved high-accuracy conflict is left blank instead of exporting a guessed value", async () => {
  const previous = {
    ...modelResult.records[0],
    cardNumber: "X102",
    videoCode: "C005",
    scene: "207",
    shot: "01",
    take: "05",
  };
  const base = {
    ...modelResult.records[0],
    cardNumber: "X102",
    videoCode: "C006",
    scene: "207",
    shot: "13",
    take: "05",
  };
  let call = 0;
  const fetchImpl = async () => {
    call += 1;
    const records =
      call === 1
        ? [previous, base]
        : call === 2
          ? [previous, { ...base, shot: "01", take: "06" }]
          : [];
    return jsonResponse({
      output_text: JSON.stringify({ sheetTitle: null, records, warnings: [] }),
    });
  };

  const result = await recognizeSlate(
    {
      providerId: "openai",
      modelId: "openai/gpt-4o-mini",
      imageDataUrl,
      accuracyMode: "high",
    },
    { env: { OPENAI_API_KEY: "test-key" }, fetchImpl },
  );

  assert.equal(call, 3);
  const unresolved = result.result.records.find(
    (record) => materialKey(record) === "X102C006",
  );
  assert.equal(unresolved.shot, null);
  assert.equal(unresolved.take, null);
  assert.deepEqual(unresolved.reviewRequiredFields, ["shot", "take"]);
  assert.match(result.result.warnings.join("\n"), /最终复核仍无法确认.*已留空/);
});

test("missing provider key returns a readable client error", async () => {
  await assert.rejects(
    recognizeSlate(
      {
        providerId: "openrouter",
        modelId: "qwen/qwen3.7-flash",
        imageDataUrl,
      },
      { env: {}, fetchImpl: async () => assert.fail("must not fetch") },
    ),
    /OPENROUTER_API_KEY/,
  );
});

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function materialRange(cardNumber, start, end) {
  return Array.from(
    { length: end - start + 1 },
    (_, index) => `${cardNumber}C${String(start + index).padStart(3, "0")}`,
  );
}

function compatibleEnv(overrides = {}) {
  return {
    OPENAI_COMPATIBLE_API_KEY: "compatible-key",
    OPENAI_COMPATIBLE_BASE_URL: "https://vision.example/v1/",
    OPENAI_COMPATIBLE_MODEL: "vendor/vision-ocr",
    OPENAI_COMPATIBLE_API_MODE: "chat-completions",
    OPENAI_COMPATIBLE_JSON_MODE: "json_object",
    ...overrides,
  };
}
