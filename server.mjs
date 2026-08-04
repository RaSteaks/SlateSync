import http from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { recognizeSlate } from "./lib/ai-client.mjs";
import { loadWorkflowConfig, publicConfig } from "./lib/config.mjs";
import {
  discoverVisionModels,
  staticProviderModels,
} from "./lib/model-discovery.mjs";
import { validateApiRequest } from "./lib/request-security.mjs";

const ROOT = fileURLToPath(new URL(".", import.meta.url));
const PUBLIC_DIR = join(ROOT, "public");
const PDFJS_DIR = join(ROOT, "node_modules", "pdfjs-dist", "build");
const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; img-src 'self' data: blob:; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

await loadLocalEnv(join(ROOT, ".env"));

const workflowConfigPath = resolve(
  ROOT,
  process.env.SLATESYNC_CONFIG_PATH || "slatesync.config.json",
);
const workflowConfig = await loadWorkflowConfig(workflowConfigPath);
const settings = serverSettings(process.env);
const recognitionLimiter = createTaskLimiter(settings.maxConcurrentRecognitions);
const startedAt = Date.now();
let shuttingDown = false;

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url || "/", "http://localhost");

    if (request.method === "GET" && url.pathname === "/healthz") {
      return sendJson(response, shuttingDown ? 503 : 200, {
        status: shuttingDown ? "stopping" : "ok",
        uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      });
    }

    if (request.method === "GET" && url.pathname === "/readyz") {
      const config = publicConfig(process.env, workflowConfig);
      const recognitionConfigured = config.providers.some(
        (provider) => provider.configured,
      );
      const ocrAvailable = Boolean(config.ocr?.enabled && config.ocr?.available);
      const ready =
        !shuttingDown &&
        recognitionConfigured &&
        (!config.ocr?.required || ocrAvailable);
      return sendJson(response, ready ? 200 : 503, {
        status: shuttingDown ? "stopping" : ready ? "ready" : "not-ready",
        recognitionConfigured,
        ocrAvailable,
        activeRecognitions: recognitionLimiter.active,
        maxConcurrentRecognitions: recognitionLimiter.limit,
      });
    }

    if (shuttingDown) {
      return sendJson(response, 503, { error: "服务器正在停止，请稍后重试" });
    }

    if (!authorizedRequest(request.headers, settings.basicAuth)) {
      return sendUnauthorized(response);
    }

    if (request.method === "GET" && url.pathname === "/api/config") {
      return sendJson(response, 200, clientConfig());
    }

    if (request.method === "GET" && url.pathname === "/api/models") {
      const providerId = url.searchParams.get("provider") || "";
      try {
        const result = await discoverVisionModels(providerId, {
          forceRefresh: url.searchParams.get("refresh") === "1",
        });
        return sendJson(response, 200, clientModelDiscovery(result));
      } catch (error) {
        if (Number(error.status) === 400) throw error;
        const fallback = staticProviderModels(providerId);
        return sendJson(response, 200, {
          provider: providerId,
          source: "static-fallback",
          refreshedAt: new Date().toISOString(),
          availableModelCount: null,
          visionModelCount: fallback.length,
          fixedModelCount: fallback.length,
          warning: error.message || "无法读取实时模型列表",
          models: fallback.map(withoutPricing),
        });
      }
    }

    if (request.method === "POST" && url.pathname === "/api/recognize") {
      validateApiRequest(request.headers);
      const release = recognitionLimiter.acquire();
      try {
        const body = await readJsonBody(request, settings.maxBodyBytes);
        const result = await recognizeSlate(recognitionInput(body));
        return sendJson(response, 200, clientRecognitionResult(result));
      } finally {
        release();
      }
    }

    if (request.method === "POST" && url.pathname === "/api/recognize-stream") {
      validateApiRequest(request.headers);
      const release = recognitionLimiter.acquire();
      try {
        const body = await readJsonBody(request, settings.maxBodyBytes);
        return await streamRecognition(response, recognitionInput(body));
      } finally {
        release();
      }
    }

    if (request.method === "GET") {
      if (url.pathname === "/vendor/pdfjs/pdf.mjs") {
        return serveFile(join(PDFJS_DIR, "pdf.mjs"), response);
      }
      if (url.pathname === "/vendor/pdfjs/pdf.worker.mjs") {
        return serveFile(join(PDFJS_DIR, "pdf.worker.mjs"), response);
      }
      return serveStatic(url.pathname, response);
    }

    return sendJson(response, 404, { error: "接口不存在" });
  } catch (error) {
    const { status, message } = publicError(error);
    if (status >= 500) {
      console.error(error);
    }
    return sendJson(response, status, { error: message });
  }
});

server.headersTimeout = settings.headersTimeoutMs;
server.requestTimeout = settings.requestTimeoutMs;
server.keepAliveTimeout = settings.keepAliveTimeoutMs;
server.maxRequestsPerSocket = settings.maxRequestsPerSocket;
server.on("error", (error) => {
  console.error(`SlateSync 启动失败：${error.message}`);
  process.exitCode = 1;
});

function recognitionInput(body) {
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
    fieldFormats: workflowConfig.resolve.fieldFormats,
  };
}

async function streamRecognition(response, input) {
  let writable = true;
  response.on("close", () => {
    writable = false;
  });
  const sendEvent = (event) => {
    if (!writable || response.destroyed || response.writableEnded) return;
    response.write(`${JSON.stringify(event)}\n`);
  };

  try {
    response.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    });
    response.flushHeaders?.();
    const result = await recognizeSlate(input, { onProgress: sendEvent });
    sendEvent({ type: "result", data: clientRecognitionResult(result) });
  } catch (error) {
    const { status, message } = publicError(error);
    if (status >= 500) console.error(error);
    sendEvent({ type: "error", status, error: message });
  } finally {
    if (writable && !response.destroyed && !response.writableEnded) response.end();
  }
}

function publicError(error) {
  const status = Number(error?.status) || 500;
  const message =
    status === 500 && !error?.providerError
      ? "服务器处理请求时发生错误"
      : error?.message || "服务器处理请求时发生错误";
  return { status, message };
}

server.listen(settings.port, settings.host, () => {
  const address = server.address();
  const listeningPort = typeof address === "object" && address
    ? address.port
    : settings.port;
  console.log(`SlateSync 已启动：http://${settings.host}:${listeningPort}`);
  const configured = publicConfig().providers
    .filter((provider) => provider.configured)
    .map((provider) => provider.label);
  console.log(
    configured.length
      ? `已配置：${configured.join("、")}`
      : "尚未配置 API Key，请复制 .env.example 为 .env 后填写。",
  );
  console.log(
    settings.basicAuth
      ? "HTTP Basic Auth 已启用。"
      : "HTTP Basic Auth 未启用；仅适合受信任的本地网络。",
  );
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.once(signal, () => gracefulShutdown(signal));
}

function gracefulShutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`收到 ${signal}，停止接收新请求并等待进行中的任务完成。`);

  const deadline = setTimeout(() => {
    console.error(
      `等待 ${settings.shutdownTimeoutMs}ms 后仍有任务未结束，关闭剩余连接。`,
    );
    server.closeAllConnections?.();
    process.exitCode = 1;
  }, settings.shutdownTimeoutMs);
  deadline.unref();

  server.close((error) => {
    clearTimeout(deadline);
    if (error) {
      console.error("服务器停止失败：", error);
      process.exitCode = 1;
      return;
    }
    console.log("SlateSync 已安全停止。");
  });
  server.closeIdleConnections?.();
}

async function serveStatic(pathname, response) {
  const requested = pathname === "/" ? "/index.html" : pathname;
  const safePath = normalize(requested).replace(/^(\.\.(\/|\\|$))+/, "");
  const absolutePath = join(PUBLIC_DIR, safePath);

  if (!absolutePath.startsWith(PUBLIC_DIR)) {
    return sendJson(response, 403, { error: "禁止访问" });
  }

  try {
    return await serveFile(absolutePath, response);
  } catch (error) {
    if (error.code === "ENOENT") {
      return sendJson(response, 404, { error: "页面不存在" });
    }
    throw error;
  }
}

async function serveFile(absolutePath, response) {
  const contents = await readFile(absolutePath);
  response.writeHead(200, {
    ...SECURITY_HEADERS,
    "Content-Type": contentType(absolutePath),
    "Cache-Control": "no-cache",
  });
  response.end(contents);
}

function readJsonBody(request, maxBodyBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    let settled = false;

    request.on("data", (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > maxBodyBytes) {
        settled = true;
        reject(
          statusError(
            `上传内容超过 ${Math.floor(maxBodyBytes / 1024 / 1024)} MB`,
            413,
          ),
        );
        request.resume();
        return;
      }
      chunks.push(chunk);
    });

    request.on("end", () => {
      if (settled) return;
      settled = true;
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(statusError("请求内容不是有效 JSON", 400));
      }
    });
    request.on("error", (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function sendJson(response, status, value) {
  response.writeHead(status, {
    ...SECURITY_HEADERS,
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(JSON.stringify(value));
}

function sendUnauthorized(response) {
  response.writeHead(401, {
    ...SECURITY_HEADERS,
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
    "WWW-Authenticate": 'Basic realm="SlateSync", charset="UTF-8"',
  });
  response.end("需要身份验证");
}

function contentType(path) {
  return (
    {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "text/javascript; charset=utf-8",
      ".mjs": "text/javascript; charset=utf-8",
      ".svg": "image/svg+xml",
      ".png": "image/png",
    }[extname(path)] || "application/octet-stream"
  );
}

function clientModelDiscovery(result) {
  return {
    ...result,
    models: (result.models || []).map(withoutPricing),
  };
}

function clientConfig() {
  const config = publicConfig(process.env, workflowConfig);
  return {
    ...config,
    upload: {
      ...config.upload,
      maxRequestBytes: settings.maxBodyBytes,
    },
  };
}

function withoutPricing(model) {
  const publicModel = { ...model };
  delete publicModel.price;
  delete publicModel.prices;
  delete publicModel.pricePerMillion;
  delete publicModel.priceUpdatedAt;
  return publicModel;
}

function clientRecognitionResult(result) {
  const publicResult = { ...result };
  delete publicResult.cost;
  if (publicResult.usage && typeof publicResult.usage === "object") {
    publicResult.usage = { ...publicResult.usage };
    delete publicResult.usage.cost;
  }
  return publicResult;
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

function statusError(message, status) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function serverSettings(env) {
  return {
    host: cleanSetting(env.HOST) || "127.0.0.1",
    port: integerSetting(env.PORT, 4173, 0, 65_535, "PORT"),
    maxBodyBytes:
      integerSetting(env.MAX_BODY_MB, 80, 20, 200, "MAX_BODY_MB") *
      1024 *
      1024,
    basicAuth: basicAuthSetting(env),
    headersTimeoutMs: integerSetting(
      env.SERVER_HEADERS_TIMEOUT_MS,
      60_000,
      5_000,
      120_000,
      "SERVER_HEADERS_TIMEOUT_MS",
    ),
    requestTimeoutMs: integerSetting(
      env.SERVER_REQUEST_TIMEOUT_MS,
      300_000,
      30_000,
      3_600_000,
      "SERVER_REQUEST_TIMEOUT_MS",
    ),
    keepAliveTimeoutMs: integerSetting(
      env.SERVER_KEEP_ALIVE_TIMEOUT_MS,
      5_000,
      1_000,
      60_000,
      "SERVER_KEEP_ALIVE_TIMEOUT_MS",
    ),
    maxRequestsPerSocket: integerSetting(
      env.SERVER_MAX_REQUESTS_PER_SOCKET,
      1_000,
      1,
      100_000,
      "SERVER_MAX_REQUESTS_PER_SOCKET",
    ),
    maxConcurrentRecognitions: integerSetting(
      env.MAX_CONCURRENT_RECOGNITIONS,
      1,
      1,
      16,
      "MAX_CONCURRENT_RECOGNITIONS",
    ),
    shutdownTimeoutMs: integerSetting(
      env.SHUTDOWN_TIMEOUT_MS,
      300_000,
      5_000,
      1_800_000,
      "SHUTDOWN_TIMEOUT_MS",
    ),
  };
}

function basicAuthSetting(env) {
  const username = cleanSetting(env.SLATESYNC_AUTH_USERNAME);
  const password = cleanSetting(env.SLATESYNC_AUTH_PASSWORD);
  if (!username && !password) return null;
  if (!username || !password) {
    throw new Error(
      "SLATESYNC_AUTH_USERNAME 与 SLATESYNC_AUTH_PASSWORD 必须同时配置",
    );
  }
  return { username, password };
}

function authorizedRequest(headers, expected) {
  if (!expected) return true;
  const match = String(headers.authorization || "").match(/^Basic\s+(.+)$/i);
  if (!match) return false;
  let decoded;
  try {
    decoded = Buffer.from(match[1], "base64").toString("utf8");
  } catch {
    return false;
  }
  const separator = decoded.indexOf(":");
  if (separator < 0) return false;
  return (
    secureEqual(decoded.slice(0, separator), expected.username) &&
    secureEqual(decoded.slice(separator + 1), expected.password)
  );
}

function secureEqual(actual, expected) {
  const actualHash = createHash("sha256").update(actual).digest();
  const expectedHash = createHash("sha256").update(expected).digest();
  return timingSafeEqual(actualHash, expectedHash);
}

function integerSetting(value, fallback, minimum, maximum, name) {
  if (value == null || String(value).trim() === "") return fallback;
  const numeric = Number(value);
  if (!Number.isInteger(numeric) || numeric < minimum || numeric > maximum) {
    throw new Error(`${name} 必须是 ${minimum}–${maximum} 之间的整数`);
  }
  return numeric;
}

function cleanSetting(value) {
  return typeof value === "string" ? value.trim() : "";
}

function createTaskLimiter(limit) {
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
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
      };
    },
  };
}
