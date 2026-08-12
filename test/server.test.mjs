import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("server exposes health endpoints and stops gracefully", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-server-"));
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      HOST: "127.0.0.1",
      PORT: "0",
      OPENAI_API_KEY: "test-key",
      OPENAI_BASE_URL: "http://127.0.0.1:1/v1",
      OPENROUTER_API_KEY: "",
      TOKENPLAN_API_KEY: "",
      OPENAI_COMPATIBLE_API_KEY: "",
      PADDLEOCR_ENABLED: "false",
      PADDLEOCR_REQUIRED: "false",
      VISIONOCR_ENABLED: "false",
      SLATESYNC_AUTH_USERNAME: "review-user",
      SLATESYNC_AUTH_PASSWORD: "review-password",
      SLATESYNC_DATA_DIR: dataDir,
      SHUTDOWN_TIMEOUT_MS: "5000",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let output = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    output += chunk;
  });
  child.stderr.on("data", (chunk) => {
    output += chunk;
  });

  try {
    const port = await waitForPort(child, () => output);
    const baseUrl = `http://127.0.0.1:${port}`;
    const authorization = basicAuthorization("review-user", "review-password");

    const healthResponse = await fetch(`${baseUrl}/healthz`);
    assert.equal(healthResponse.status, 200);
    assert.deepEqual(Object.keys(await healthResponse.json()).sort(), [
      "status",
      "uptimeSeconds",
    ]);

    const readyResponse = await fetch(`${baseUrl}/readyz`);
    assert.equal(readyResponse.status, 200);
    assert.deepEqual(await readyResponse.json(), {
      status: "ready",
      recognitionConfigured: true,
      ocrAvailable: false,
      activeRecognitions: 0,
      maxConcurrentRecognitions: 1,
    });

    const unauthorizedResponse = await fetch(`${baseUrl}/api/config`);
    assert.equal(unauthorizedResponse.status, 401);
    assert.match(
      unauthorizedResponse.headers.get("www-authenticate") || "",
      /^Basic /,
    );

    const configResponse = await fetch(`${baseUrl}/api/config`, {
      headers: { Authorization: authorization },
    });
    assert.equal(configResponse.status, 200);
    const publicConfig = await configResponse.json();
    assert.equal(JSON.stringify(publicConfig).includes("test-key"), false);
    assert.equal(JSON.stringify(publicConfig).includes("price"), false);
    assert.equal(publicConfig.upload.maxRequestBytes, 80 * 1024 * 1024);
    assert.deepEqual(publicConfig.workflow, {
      slate: { maxDirectoryDepth: 4 },
      resolve: {
        fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      },
    });

    const modelsResponse = await fetch(`${baseUrl}/api/models?provider=openai`, {
      headers: { Authorization: authorization },
    });
    assert.equal(modelsResponse.status, 200);
    const models = await modelsResponse.json();
    assert.equal(
      models.models.some((model) => model.id === "openai/gpt-5.6-terra"),
      true,
    );
    assert.equal(JSON.stringify(models).includes("price"), false);

    const pageResponse = await fetch(baseUrl, {
      headers: { Authorization: authorization },
    });
    assert.equal(pageResponse.status, 200);
    assert.match(
      pageResponse.headers.get("content-security-policy") || "",
      /script-src 'self'/,
    );
    assert.match(await pageResponse.text(), /场记单识别与回填/);

    const slowRequest = http.request({
      host: "127.0.0.1",
      port,
      path: "/api/recognize",
      method: "POST",
      headers: {
        Authorization: authorization,
        "Content-Type": "application/json",
      },
    });
    const slowResponse = responseResult(slowRequest);
    slowRequest.write('{"provider":');
    await waitForActiveRecognitions(baseUrl, 1);

    const busyResponse = await fetch(`${baseUrl}/api/recognize`, {
      method: "POST",
      headers: {
        Authorization: authorization,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    assert.equal(busyResponse.status, 429);
    assert.match((await busyResponse.json()).error, /正在处理 1 个识别任务/);

    slowRequest.end("invalid}");
    assert.equal((await slowResponse).status, 400);
    await waitForActiveRecognitions(baseUrl, 0);

    child.kill("SIGTERM");
    const code = await waitForExit(child);
    assert.equal(code, 0, output);
    assert.match(output, /SlateSync 已安全停止/);
  } finally {
    if (child.exitCode == null && child.signalCode == null) {
      child.kill("SIGKILL");
    }
    await rm(dataDir, { recursive: true, force: true });
  }
});

test("readiness rejects missing providers and unavailable required OCR", async () => {
  const cases = [
    {
      name: "missing provider",
      env: {
        OPENAI_API_KEY: "",
        PADDLEOCR_ENABLED: "false",
        PADDLEOCR_REQUIRED: "false",
      },
    },
    {
      name: "required OCR unavailable",
      env: {
        OPENAI_API_KEY: "test-key",
        OPENAI_BASE_URL: "http://127.0.0.1:1/v1",
        PADDLEOCR_ENABLED: "false",
        PADDLEOCR_REQUIRED: "true",
        VISIONOCR_ENABLED: "false",
      },
    },
  ];

  for (const scenario of cases) {
    const dataDir = await mkdtemp(join(tmpdir(), "slatesync-server-"));
    const child = spawn(process.execPath, ["server.mjs"], {
      cwd: new URL("..", import.meta.url),
      env: {
        ...process.env,
        HOST: "127.0.0.1",
        PORT: "0",
        OPENROUTER_API_KEY: "",
        TOKENPLAN_API_KEY: "",
        DASHSCOPE_API_KEY: "",
        OPENAI_COMPATIBLE_API_KEY: "",
        SLATESYNC_AUTH_USERNAME: "",
        SLATESYNC_AUTH_PASSWORD: "",
        SLATESYNC_DATA_DIR: dataDir,
        SHUTDOWN_TIMEOUT_MS: "5000",
        ...scenario.env,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      output += chunk;
    });
    child.stderr.on("data", (chunk) => {
      output += chunk;
    });

    try {
      const port = await waitForPort(child, () => output);
      const response = await fetch(`http://127.0.0.1:${port}/readyz`);
      assert.equal(response.status, 503, scenario.name);
      assert.equal((await response.json()).status, "not-ready", scenario.name);
      child.kill("SIGTERM");
      assert.equal(await waitForExit(child), 0, output);
    } finally {
      if (child.exitCode == null && child.signalCode == null) {
        child.kill("SIGKILL");
      }
      await rm(dataDir, { recursive: true, force: true });
    }
  }
});

test("web-submitted API key configures a provider until cleared", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-server-"));
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      HOST: "127.0.0.1",
      PORT: "0",
      OPENAI_API_KEY: "",
      OPENAI_BASE_URL: "http://127.0.0.1:1/v1",
      OPENROUTER_API_KEY: "",
      TOKENPLAN_API_KEY: "",
      DASHSCOPE_API_KEY: "",
      OPENAI_COMPATIBLE_API_KEY: "",
      PADDLEOCR_ENABLED: "false",
      PADDLEOCR_REQUIRED: "false",
      VISIONOCR_ENABLED: "false",
      SLATESYNC_AUTH_USERNAME: "",
      SLATESYNC_AUTH_PASSWORD: "",
      SLATESYNC_DATA_DIR: dataDir,
      SHUTDOWN_TIMEOUT_MS: "5000",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let output = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    output += chunk;
  });
  child.stderr.on("data", (chunk) => {
    output += chunk;
  });

  try {
    const port = await waitForPort(child, () => output);
    const baseUrl = `http://127.0.0.1:${port}`;
    const postKey = (provider, apiKey) =>
      fetch(`${baseUrl}/api/provider-key`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Origin: baseUrl,
        },
        body: JSON.stringify({ provider, apiKey }),
      });

    let config = await (await fetch(`${baseUrl}/api/config`)).json();
    assert.equal(
      config.providers.find((provider) => provider.id === "openai").configured,
      false,
    );

    const saved = await postKey("openai", "runtime-secret");
    assert.equal(saved.status, 200);
    assert.equal((await saved.json()).configured, true);

    config = await (await fetch(`${baseUrl}/api/config`)).json();
    assert.equal(
      config.providers.find((provider) => provider.id === "openai").configured,
      true,
    );

    const cleared = await postKey("openai", "");
    assert.equal((await cleared.json()).configured, false);
    config = await (await fetch(`${baseUrl}/api/config`)).json();
    assert.equal(
      config.providers.find((provider) => provider.id === "openai").configured,
      false,
    );

    const unknown = await postKey("no-such-provider", "x");
    assert.equal(unknown.status, 400);

    child.kill("SIGTERM");
    assert.equal(await waitForExit(child), 0, output);
  } finally {
    if (child.exitCode == null && child.signalCode == null) {
      child.kill("SIGKILL");
    }
    await rm(dataDir, { recursive: true, force: true });
  }
});

function waitForPort(child, readOutput) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`服务器启动超时\n${readOutput()}`));
    }, 10_000);

    const inspect = () => {
      const match = readOutput().match(/127\.0\.0\.1:(\d+)/);
      if (!match) return;
      clearTimeout(timeout);
      child.stdout.off("data", inspect);
      resolve(Number(match[1]));
    };

    child.stdout.on("data", inspect);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`服务器提前退出（${code}）\n${readOutput()}`));
    });
  });
}

function waitForExit(child) {
  if (child.exitCode != null) return Promise.resolve(child.exitCode);
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error("服务器未在超时前退出"));
    }, 10_000);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      resolve(code);
    });
  });
}

function basicAuthorization(username, password) {
  return `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
}

function responseResult(request) {
  return new Promise((resolve, reject) => {
    request.once("response", (response) => {
      response.resume();
      response.once("end", () => resolve({ status: response.statusCode }));
    });
    request.once("error", reject);
  });
}

async function waitForActiveRecognitions(baseUrl, expected) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const response = await fetch(`${baseUrl}/readyz`);
    const data = await response.json();
    if (data.activeRecognitions === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`识别并发数未变为 ${expected}`);
}
