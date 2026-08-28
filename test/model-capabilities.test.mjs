import test from "node:test";
import assert from "node:assert/strict";
import { checkOpenAiCompatibleJsonSchema } from "../lib/model-capabilities.mjs";

test("JSON Schema capability probe accepts a valid Chat Completions response", async () => {
  let request;
  const result = await checkOpenAiCompatibleJsonSchema({
    env: {
      OPENAI_COMPATIBLE_API_KEY: "local-test-key",
      OPENAI_COMPATIBLE_BASE_URL: "http://127.0.0.1:8000/v1",
      OPENAI_COMPATIBLE_MODEL: "Qwen3.8-27B-MLX-4bit",
      OPENAI_COMPATIBLE_API_MODE: "chat-completions",
    },
    fetchImpl: async (url, options) => {
      request = { url, options };
      return jsonResponse({
        choices: [{ message: { content: '{"ok":true,"marker":"slatesync"}' } }],
      });
    },
  });

  assert.equal(result.supported, true);
  assert.equal(result.transport, "chat-completions");
  assert.equal(request.url, "http://127.0.0.1:8000/v1/chat/completions");
  const body = JSON.parse(request.options.body);
  assert.equal(body.response_format.type, "json_schema");
  assert.equal(body.response_format.json_schema.strict, true);
  assert.equal(JSON.stringify(body).includes("data:image"), false);
});

test("JSON Schema capability probe reports provider rejection instead of throwing", async () => {
  const result = await checkOpenAiCompatibleJsonSchema({
    env: {
      OPENAI_COMPATIBLE_API_KEY: "local-test-key",
      OPENAI_COMPATIBLE_BASE_URL: "http://127.0.0.1:8000/v1",
      OPENAI_COMPATIBLE_MODEL: "local-vision",
    },
    fetchImpl: async () => jsonResponse({
      error: { message: "response_format json_schema is unsupported" },
    }, 400),
  });

  assert.equal(result.supported, false);
  assert.equal(result.status, 400);
  assert.match(result.message, /接口拒绝 JSON Schema/);
});

test("JSON Schema capability probe supports the Responses transport shape", async () => {
  let request;
  const result = await checkOpenAiCompatibleJsonSchema({
    env: {
      OPENAI_COMPATIBLE_API_KEY: "local-test-key",
      OPENAI_COMPATIBLE_BASE_URL: "https://local.example/v1/",
      OPENAI_COMPATIBLE_MODEL: "local-vision",
      OPENAI_COMPATIBLE_API_MODE: "responses",
    },
    fetchImpl: async (url, options) => {
      request = { url, options };
      return jsonResponse({ output_text: '{"ok":true,"marker":"slatesync"}' });
    },
  });

  assert.equal(result.supported, true);
  assert.equal(request.url, "https://local.example/v1/responses");
  const body = JSON.parse(request.options.body);
  assert.equal(body.text.format.type, "json_schema");
  assert.equal(body.store, false);
});

test("JSON Schema capability probe validates local endpoint configuration", async () => {
  await assert.rejects(
    checkOpenAiCompatibleJsonSchema({ env: {} }),
    /尚未配置 OPENAI_COMPATIBLE_API_KEY、OPENAI_COMPATIBLE_BASE_URL、OPENAI_COMPATIBLE_MODEL/,
  );
});

function jsonResponse(value, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => JSON.stringify(value),
  };
}
