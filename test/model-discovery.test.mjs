import test from "node:test";
import assert from "node:assert/strict";
import { CUSTOM_MODEL_ID, resolveModel } from "../lib/config.mjs";
import {
  clearModelDiscoveryCache,
  discoverVisionModels,
  staticProviderModels,
} from "../lib/model-discovery.mjs";

test("OpenAI discovery intersects Key access with the visual catalog and keeps fixed models first", async () => {
  clearModelDiscoveryCache();
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request };
    return jsonResponse({
      object: "list",
      data: [
        { id: "gpt-5.6-sol", object: "model" },
        { id: "gpt-5.6-terra", object: "model" },
        { id: "gpt-5.6-luna", object: "model" },
        { id: "gpt-5.4-mini", object: "model" },
        { id: "gpt-5-mini", object: "model" },
        { id: "gpt-4o-mini", object: "model" },
        { id: "gpt-4", object: "model" },
        { id: "text-embedding-3-large", object: "model" },
      ],
    });
  };

  const result = await discoverVisionModels("openai", {
    env: { OPENAI_API_KEY: "test-openai-key" },
    fetchImpl,
    cache: false,
  });

  assert.equal(captured.url, "https://api.openai.com/v1/models");
  assert.equal(captured.request.method, "GET");
  assert.equal(
    captured.request.headers.Authorization,
    "Bearer test-openai-key",
  );
  assert.deepEqual(
    result.models.slice(0, 3).map((model) => model.id),
    [
      "openai/gpt-5.6-luna",
      "openai/gpt-5.6-terra",
      "openai/gpt-4o-mini",
    ],
  );
  assert.equal(result.models[0].fixed, true);
  assert.equal(result.models[3].fixed, false);
  assert.deepEqual(
    result.models.slice(3).map((model) => model.id),
    [
      "openai/gpt-5.6-sol",
      "openai/gpt-5.4-mini",
      "openai/gpt-5-mini",
    ],
  );
  assert.equal(result.fixedModelCount, 3);
  assert.equal(result.models.some((model) => model.id === "openai/gpt-4"), false);
  assert.equal(result.availableModelCount, 8);
  assert.equal(result.visionModelCount, 6);
  assert.equal(
    resolveModel("openai", "openai/gpt-5.6-terra").apiId,
    "gpt-5.6-terra",
  );
});

test("OpenRouter discovery trusts declared modalities, uses live prices, and excludes text-only models", async () => {
  clearModelDiscoveryCache();
  const fetchImpl = async () =>
    jsonResponse({
      data: [
        routerModel("qwen/qwen3.7-flash", ["text", "image"], ["text"], {
          prompt: "0.00000003",
          completion: "0.00000013",
        }),
        routerModel("openai/gpt-5.6-luna", ["text", "image"], ["text"], {
          prompt: "0.0000005",
          completion: "0.000003",
        }),
        routerModel("openai/gpt-5.6-terra", ["text", "image"], ["text"], {
          prompt: "0.0000025",
          completion: "0.000015",
        }),
        routerModel("openai/gpt-4o-mini", ["text", "image"], ["text"], {
          prompt: "0.00000015",
          completion: "0.0000006",
        }),
        routerModel("qwen/qwen3.7-plus", ["text", "image"], ["text"], {
          prompt: "0.00000032",
          completion: "0.00000128",
        }),
        routerModel("qwen/qwen3.7-max", ["text"], ["text"], {
          prompt: "0.000001",
          completion: "0.000004",
        }),
        routerModel("vendor/image-generator", ["text", "image"], ["image"], {
          prompt: "0.000001",
          completion: "0.000001",
        }),
        routerModel("openai/gpt-5-image", ["text", "image"], ["text", "image"], {
          prompt: "0.00001",
          completion: "0.00001",
        }),
      ],
    });

  const result = await discoverVisionModels("openrouter", {
    env: { OPENROUTER_API_KEY: "router-key" },
    fetchImpl,
    cache: false,
  });

  assert.deepEqual(
    result.models.slice(0, 4).map((model) => model.id),
    [
      "qwen/qwen3.7-flash",
      "openai/gpt-5.6-luna",
      "openai/gpt-5.6-terra",
      "openai/gpt-4o-mini",
    ],
  );
  assert.equal(result.models[2].fixed, true);
  assert.equal(result.models[0].vendor, "qwen");
  assert.equal(result.models.find((model) => model.id === "openai/gpt-5.6-luna").vendor, "openai");
  assert.equal(
    result.models.find((model) => model.id === "qwen/qwen3.7-plus")
      .pricePerMillion.input,
    0.32,
  );
  assert.equal(result.models.some((model) => model.id.includes("max")), false);
  assert.equal(result.models.some((model) => model.id.includes("generator")), false);
  assert.equal(result.models.some((model) => model.id.includes("gpt-5-image")), false);
  assert.equal(
    resolveModel("openrouter", "qwen/qwen3.7-plus").apiId,
    "qwen/qwen3.7-plus",
  );
});

test("Token Plan discovery keeps licensed visual models and supports static fallback", async () => {
  clearModelDiscoveryCache();
  let captured;
  const fetchImpl = async (url, request) => {
    captured = { url, request };
    return jsonResponse({
      data: [
        { id: "qwen3.7-plus" },
        routerModel("qwen3.8-max", ["text", "image"], ["text"], {}),
        routerModel("qwen3.7-max", ["text"], ["text"], {}),
        routerModel("vendor/vision-model", ["text", "image"], ["text"], {}),
      ],
    });
  };

  const env = { TOKENPLAN_API_KEY: "licensed-test-key" };
  const result = await discoverVisionModels("tokenplan", {
    env,
    fetchImpl,
    cache: false,
  });

  assert.equal(
    captured.url,
    "https://dashscope.aliyuncs.com/compatible-mode/v1/models",
  );
  assert.equal(
    captured.request.headers.Authorization,
    "Bearer licensed-test-key",
  );
  assert.deepEqual(
    result.models.map((model) => model.id),
    ["qwen3.7-plus", "qwen3.8-max", "vendor/vision-model"],
  );
  assert.equal(result.models[0].fixed, true);
  assert.equal(result.models[1].fixed, true);
  assert.equal(result.models[2].fixed, false);
  assert.equal(result.models[0].qualityLabel, "A");
  assert.equal(result.models[0].valueLabel, "A");
  assert.equal(result.models.some((model) => model.id === "qwen3.7-max"), false);

  const fallback = staticProviderModels("tokenplan", env);
  assert.deepEqual(
    fallback.map((model) => model.id),
    ["qwen3.7-plus", "qwen3.8-max", "qwen3.6-flash", "qwen3.6-plus"],
  );
  assert.equal(
    fallback.find((model) => model.id === "qwen3.6-flash").valueLabel,
    "A+",
  );
  assert.equal(fallback.every((model) => model.verifiedAvailable === false), true);
});

test("OpenAI-compatible discovery keeps the configured model fixed and exposes declared vision models", async () => {
  clearModelDiscoveryCache();
  const env = {
    OPENAI_COMPATIBLE_API_KEY: "compatible-key",
    OPENAI_COMPATIBLE_BASE_URL: "https://vision.example/v1",
    OPENAI_COMPATIBLE_MODEL: "vendor/fixed-ocr",
  };
  const fetchImpl = async () =>
    jsonResponse({
      data: [
        routerModel("vendor/other-vision", ["text", "image"], ["text"], {
          prompt: "0.0000002",
          completion: "0.000001",
        }),
        { id: "vendor/fixed-ocr" },
        routerModel("vendor/text-only", ["text"], ["text"], {}),
      ],
    });

  const result = await discoverVisionModels("openai-compatible", {
    env,
    fetchImpl,
    cache: false,
  });

  assert.equal(result.models[0].id, CUSTOM_MODEL_ID);
  assert.equal(result.models[0].apiId, "vendor/fixed-ocr");
  assert.equal(result.models[0].fixed, true);
  assert.equal(result.models[1].id, "vendor/other-vision");
  assert.equal(
    resolveModel("openai-compatible", "vendor/other-vision", env).apiId,
    "vendor/other-vision",
  );
});

test("OpenAI-compatible model changes invalidate the cached custom descriptor", async () => {
  clearModelDiscoveryCache();
  let requestCount = 0;
  const fetchImpl = async () => {
    requestCount += 1;
    return jsonResponse({ data: [{ id: "model-a" }, { id: "model-b" }] });
  };
  const envA = {
    OPENAI_COMPATIBLE_API_KEY: "compatible-key",
    OPENAI_COMPATIBLE_BASE_URL: "https://vision.example/v1",
    OPENAI_COMPATIBLE_MODEL: "model-a",
  };
  const envB = { ...envA, OPENAI_COMPATIBLE_MODEL: "model-b" };

  const first = await discoverVisionModels("openai-compatible", { env: envA, fetchImpl });
  assert.equal(first.models.find((model) => model.id === CUSTOM_MODEL_ID).apiId, "model-a");
  // Resolution must use the current setting even before the next discovery call.
  assert.equal(resolveModel("openai-compatible", CUSTOM_MODEL_ID, envB).apiId, "model-b");

  const second = await discoverVisionModels("openai-compatible", { env: envB, fetchImpl });
  assert.equal(second.models.find((model) => model.id === CUSTOM_MODEL_ID).apiId, "model-b");
  assert.equal(requestCount, 2);
});

test("static fallback is marked as unverified and never exposes credentials", () => {
  const env = { OPENAI_API_KEY: "never-expose-this" };
  const models = staticProviderModels("openai", env);
  assert.equal(models.length, 3);
  assert.equal(models.every((model) => model.verifiedAvailable === false), true);
  assert.equal(JSON.stringify(models).includes(env.OPENAI_API_KEY), false);
});

test("model discovery rejects missing configuration and unsafe base URLs", async () => {
  await assert.rejects(
    discoverVisionModels("openai", { env: {}, cache: false }),
    /尚未配置 OPENAI_API_KEY/,
  );
  await assert.rejects(
    discoverVisionModels("openai-compatible", {
      env: {
        OPENAI_COMPATIBLE_API_KEY: "key",
        OPENAI_COMPATIBLE_BASE_URL: "file:///tmp/models",
        OPENAI_COMPATIBLE_MODEL: "vision",
      },
      cache: false,
    }),
    /只支持 http:\/\/ 或 https:\/\//,
  );
  await assert.rejects(
    discoverVisionModels("tokenplan", { env: {}, cache: false }),
    /尚未配置 TOKENPLAN_API_KEY/,
  );
});

function routerModel(id, inputModalities, outputModalities, pricing) {
  return {
    id,
    architecture: {
      input_modalities: inputModalities,
      output_modalities: outputModalities,
    },
    pricing,
    supported_parameters: ["response_format", "structured_outputs"],
  };
}

function jsonResponse(value, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => JSON.stringify(value),
  };
}
