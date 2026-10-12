// Standalone HTTP server (web mode).
//
// Serves public/ as the SlateSync UI and exposes the same recognition, model
// discovery, task/diagnostic, and slate-directory APIs that the Electron build
// offers over IPC, with same-origin request guards and optional basic auth.
// Service wiring lives in lib/service/; this file owns the HTTP transport.
import http from "node:http";
import { createHash, timingSafeEqual } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import { configureModelHttpAgent } from "./lib/ai-client.mjs";
import { publicConfig } from "./lib/config.mjs";
import { createSessionCapture } from "./lib/diagnostics.mjs";
import { validateApiRequest, validateSameOriginRequest } from "./lib/request-security.mjs";
import {
  createCachedPublicConfig,
  createSlateServices,
  createTaskLimiter,
  publicError,
  statusError,
} from "./lib/service/runtime.mjs";
import {
  cleanSetting,
  createRuntimeEnv,
  integerSetting,
  loadLocalEnv,
} from "./lib/service/env.mjs";
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
  loadTask,
  updateTask,
} from "./lib/service/resources.mjs";

const ROOT = fileURLToPath(new URL(".", import.meta.url));
const PUBLIC_DIR = join(ROOT, "public");
const PDFJS_DIR = join(ROOT, "node_modules", "pdfjs-dist", "build");
// 所有响应统一携带的安全头：CSP 禁止外部脚本与页面嵌入，并收紧浏览器能力接口。
const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'self'; img-src 'self' data: blob:; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

await loadLocalEnv(join(ROOT, ".env"));
configureModelHttpAgent(process.env);

const services = await createSlateServices({ root: ROOT });
// API Key 持久化在数据目录，重启后自动恢复到运行时覆盖层。
const runtimeProviderKeys = await services.keyStore.load();
const runtimeEnv = createRuntimeEnv(runtimeProviderKeys);
// 挂到服务集合上，供 runRecognition 等共享逻辑读取叠加后的 env。
services.runtimeEnv = runtimeEnv;
const publicConfigForRequests = createCachedPublicConfig({
  getWorkflowConfig: services.getWorkflowConfig,
  runtimeEnv,
});
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
      const config = await publicConfigForRequests();
      const recognitionConfigured = config.providers.some(
        (provider) => provider.configured,
      );
      const ocrEngines = config.ocrEngines || [config.ocr];
      // 兼容只含单个 ocr 字段的旧公共配置。
      const ocrAvailable = ocrEngines.some(
        (engine) => engine.enabled && engine.available,
      );
      const ready =
        !shuttingDown &&
        recognitionConfigured &&
        (!ocrEngines.some((engine) => engine.required) || ocrAvailable);
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
      return sendJson(response, 200, await clientConfig());
    }

    if (request.method === "GET" && url.pathname === "/api/scenarios") {
      return sendJson(response, 200, {
        scenarios: await listScenarios(services),
      });
    }

    if (request.method === "GET" && url.pathname.startsWith("/api/scenarios/")) {
      const scenarioId = pathParameter(url.pathname, "/api/scenarios/");
      return sendJson(response, 200, await getScenario(services, scenarioId));
    }

    if (request.method === "POST" && url.pathname === "/api/scenarios/import") {
      validateApiRequest(request.headers);
      const body = await readJsonBody(request, settings.maxBodyBytes);
      // Accept both the bridge envelope ({ profile }) and a raw Profile so
      // command-line/API clients can import the same portable JSON document.
      return sendJson(
        response,
        201,
        await importScenario(services, body?.profile || body),
      );
    }

    if (request.method === "POST" && url.pathname === "/api/provider-key") {
      validateApiRequest(request.headers);
      const body = await readJsonBody(request, settings.maxBodyBytes);
      return sendJson(
        response,
        200,
        await saveProviderKey({
          providerId: String(body?.provider || "").trim(),
          apiKey: body?.apiKey,
          keyStore: services.keyStore,
          runtimeProviderKeys,
          runtimeEnv,
        }),
      );
    }

    if (request.method === "GET" && url.pathname === "/api/models") {
      return sendJson(
        response,
        200,
        await clientModelDiscovery(url.searchParams.get("provider") || "", {
          forceRefresh: url.searchParams.get("refresh") === "1",
          env: runtimeEnv.get(),
        }),
      );
    }

    if (request.method === "POST" && url.pathname === "/api/recognize") {
      validateApiRequest(request.headers);
      // 并发槽位在请求体接收完成后才占用：慢上传不再挤占有限的识别容量。
      const body = await readJsonBody(request, settings.maxBodyBytes);
      const release = recognitionLimiter.acquire();
      try {
        const result = await runRecognition(
          services,
          recognitionInput(body, await services.getWorkflowConfig()),
        );
        return sendJson(response, 200, clientRecognitionResult(result));
      } finally {
        release();
      }
    }

    if (request.method === "POST" && url.pathname === "/api/recognize-stream") {
      validateApiRequest(request.headers);
      const body = await readJsonBody(request, settings.maxBodyBytes);
      const release = recognitionLimiter.acquire();
      try {
        return await streamRecognition(
          response,
          recognitionInput(body, await services.getWorkflowConfig()),
        );
      } finally {
        release();
      }
    }

    if (request.method === "GET" && url.pathname === "/api/tasks") {
      const tasks = await services.taskStore.listTasks(
        listTaskOptions(url.searchParams),
      );
      return sendJson(response, 200, { tasks });
    }

    if (request.method === "GET" && url.pathname.startsWith("/api/tasks/")) {
      const taskId = pathParameter(url.pathname, "/api/tasks/");
      return sendJson(response, 200, await loadTask(services, taskId));
    }

    if (request.method === "PUT" && url.pathname.startsWith("/api/tasks/")) {
      validateApiRequest(request.headers);
      const taskId = pathParameter(url.pathname, "/api/tasks/");
      const body = await readJsonBody(request, settings.maxBodyBytes);
      await updateTask(services, taskId, body);
      return sendJson(response, 200, { id: taskId, saved: true });
    }

    if (request.method === "DELETE" && url.pathname.startsWith("/api/tasks/")) {
      // DELETE 无请求体，只需应用同源防护；浏览器 fetch 对无 body 请求
      // 不带 Content-Type，套用 JSON 校验会误杀应用自身的删除调用。
      validateSameOriginRequest(request.headers);
      const taskId = pathParameter(url.pathname, "/api/tasks/");
      await deleteTask(services, taskId);
      return sendJson(response, 200, { deleted: taskId });
    }

    if (request.method === "GET") {
      if (url.pathname === "/vendor/pdfjs/pdf.mjs") {
        return serveFile(join(PDFJS_DIR, "pdf.mjs"), response, request);
      }
      if (url.pathname === "/vendor/pdfjs/pdf.worker.mjs") {
        return serveFile(join(PDFJS_DIR, "pdf.worker.mjs"), response, request);
      }
      return serveStatic(url.pathname, response, request);
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

/**
 * 以 NDJSON（application/x-ndjson）流式执行识别：每行一个 JSON 事件，
 * 进度事件实时下发，最终以 result 或 error 事件收尾。
 * @param {http.ServerResponse} response HTTP 响应对象
 * @param {object} input recognitionInput 的结果
 * @returns {Promise<void>} 流结束即完成；并发槽位由路由的 finally 释放
 */
async function streamRecognition(response, input) {
  let writable = true;
  // 客户端提前断开后停止写入，识别仍会完成并落库。
  response.on("close", () => {
    writable = false;
  });
  const sendEvent = (event) => {
    if (!writable || response.destroyed || response.writableEnded) return;
    response.write(`${JSON.stringify(event)}\n`);
  };

  const capture = createSessionCapture();
  try {
    response.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    });
    response.flushHeaders?.();
    const result = await runRecognition(services, input, {
      onProgress: sendEvent,
      capture,
    });
    const { sessionId, taskId } = await persistRecognitionResult(
      services,
      capture.session,
      input,
      result,
    );
    sendEvent({
      type: "result",
      data: {
        ...clientRecognitionResult(result),
        diagnosticSessionId: sessionId,
        taskId,
      },
    });
  } catch (error) {
    capture.setError(error);
    await services.diagnostics.saveSession(capture.session).catch(() => {});
    const { status, message } = publicError(error);
    if (status >= 500) console.error(error);
    sendEvent({ type: "error", status, error: message });
  } finally {
    if (writable && !response.destroyed && !response.writableEnded) response.end();
  }
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

/**
 * 优雅停机：停止接收新请求，等待进行中的任务完成后再关闭 SQLite 连接。
 * @param {string} signal 触发停机的信号名，仅用于日志
 */
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

  server.close(async (error) => {
    clearTimeout(deadline);
    if (error) {
      console.error("服务器停止失败：", error);
      process.exitCode = 1;
      return;
    }
    // Close every SQLite connection after HTTP drains so WAL checkpoints and
    // file descriptors are released cleanly in Docker and local Web mode.
    await services.close();
    console.log("SlateSync 已安全停止。");
  });
  server.closeIdleConnections?.();
}

/**
 * 截取路径参数并做 URL 解码。
 * @param {string} pathname 完整请求路径
 * @param {string} prefix 路由前缀，如 "/api/tasks/"
 * @returns {string} 解码后的路径参数
 * @throws {Error} 百分号编码非法时抛 400
 */
function pathParameter(pathname, prefix) {
  const raw = pathname.slice(prefix.length);
  try {
    return decodeURIComponent(raw);
  } catch {
    throw statusError("请求路径包含无效的 URL 编码", 400);
  }
}

/**
 * 解析任务列表的 limit/offset 查询参数。
 * @param {URLSearchParams} searchParams 查询参数
 * @returns {{ limit?: number, offset?: number }} 传给 taskStore.listTasks 的
 *   选项；未提供时保持原有的全量行为，limit 上限 500 防止单次拉取过大
 */
function listTaskOptions(searchParams) {
  const options = {};
  const limit = Number(searchParams.get("limit"));
  if (Number.isInteger(limit) && limit > 0) options.limit = Math.min(limit, 500);
  const offset = Number(searchParams.get("offset"));
  if (Number.isInteger(offset) && offset > 0) options.offset = offset;
  return options;
}

/**
 * 提供 public/ 下的静态文件。
 * 路径先 normalize 并剥离前导 ".."，再以含分隔符的前缀校验，防止
 * /public-evil 之类的前缀绕过；文件不存在返回 404。
 * @param {string} pathname 请求路径
 * @param {http.ServerResponse} response HTTP 响应对象
 * @param {http.IncomingMessage} request 请求对象，用于条件请求头
 */
async function serveStatic(pathname, response, request) {
  const requested = pathname === "/" ? "/index.html" : pathname;
  const safePath = normalize(requested).replace(/^(\.\.(\/|\\|$))+/, "");
  const absolutePath = join(PUBLIC_DIR, safePath);

  if (!absolutePath.startsWith(PUBLIC_DIR + sep)) {
    return sendJson(response, 403, { error: "禁止访问" });
  }

  try {
    return await serveFile(absolutePath, response, request);
  } catch (error) {
    if (error.code === "ENOENT") {
      return sendJson(response, 404, { error: "页面不存在" });
    }
    throw error;
  }
}

// 静态文件按 mtime:size 签名缓存进内存：文件编辑后签名变化自动失效，
// 命中时避免反复从磁盘读取 PDF.js worker 这类数 MB 的资源。
const staticCache = new Map();

/**
 * 读取或命中静态文件的缓存条目。
 * @param {string} absolutePath 文件绝对路径
 * @returns {Promise<{ signature: string, contents: Buffer, gzip: Buffer|null,
 *   contentType: string, etag: string }>} gzip 仅对 text/json 类资源预压缩；
 *   ETag 由 size + mtime 生成，文件变化即变化
 */
async function staticFileEntry(absolutePath) {
  const stats = await stat(absolutePath);
  const signature = `${stats.mtimeMs}:${stats.size}`;
  const cached = staticCache.get(absolutePath);
  if (cached && cached.signature === signature) return cached;

  const contents = await readFile(absolutePath);
  const type = contentType(absolutePath);
  const entry = {
    signature,
    contents,
    gzip: /^(text\/|application\/json)/.test(type) ? gzipSync(contents) : null,
    contentType: type,
    etag: `"${stats.size.toString(16)}-${Math.round(stats.mtimeMs).toString(16)}"`,
  };
  staticCache.set(absolutePath, entry);
  return entry;
}

/**
 * 发送静态文件：ETag 命中返回 304；客户端接受 gzip 且有预压缩体时按
 * gzip 发送。Cache-Control 保持 no-cache（每次经 ETag 协商），
 * 因此文件更新后客户端仍能立即拿到新版本。
 * @param {string} absolutePath 文件绝对路径
 * @param {http.ServerResponse} response HTTP 响应对象
 * @param {http.IncomingMessage} request 请求对象
 */
async function serveFile(absolutePath, response, request) {
  const entry = await staticFileEntry(absolutePath);
  const headers = {
    ...SECURITY_HEADERS,
    "Content-Type": entry.contentType,
    "Cache-Control": "no-cache",
    ETag: entry.etag,
    Vary: "Accept-Encoding",
  };
  if (request.headers["if-none-match"] === entry.etag) {
    response.writeHead(304, headers);
    response.end();
    return;
  }
  if (entry.gzip && String(request.headers["accept-encoding"] || "").includes("gzip")) {
    headers["Content-Encoding"] = "gzip";
    response.writeHead(200, { ...headers, "Content-Length": entry.gzip.length });
    response.end(entry.gzip);
    return;
  }
  response.writeHead(200, { ...headers, "Content-Length": entry.contents.length });
  response.end(entry.contents);
}

/**
 * 读取并解析 JSON 请求体。
 * 先按 Content-Length 头预检：超大上传直接以 413 拒绝、不消耗请求体；
 * 流式上传超过上限同样抛 413。未消费完的连接由 Node 在响应结束后关闭。
 * @param {http.IncomingMessage} request 请求对象
 * @param {number} maxBodyBytes 请求体字节上限
 * @returns {Promise<object>} 解析后的 JSON 对象
 * @throws {Error} 超限抛 413；JSON 非法抛 400
 */
function readJsonBody(request, maxBodyBytes) {
  return new Promise((resolvePromise, reject) => {
    const contentLength = Number(request.headers["content-length"]);
    if (Number.isFinite(contentLength) && contentLength > maxBodyBytes) {
      // 按声明的长度直接拒绝，不 drain 超大请求体；请求体未被消费，
      // Node 会在 413 响应结束后关闭该连接。
      reject(
        statusError(
          `上传内容超过 ${Math.floor(maxBodyBytes / 1024 / 1024)} MB`,
          413,
        ),
      );
      return;
    }

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
        return;
      }
      chunks.push(chunk);
    });

    request.on("end", () => {
      if (settled) return;
      settled = true;
      try {
        resolvePromise(JSON.parse(Buffer.concat(chunks)));
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

/**
 * 按扩展名映射 Content-Type；未识别的类型按二进制流返回。
 * @param {string} path 文件路径
 * @returns {string} MIME 类型（含 charset）
 */
function contentType(path) {
  return (
    {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "text/javascript; charset=utf-8",
      ".mjs": "text/javascript; charset=utf-8",
      ".json": "application/json; charset=utf-8",
      ".map": "application/json; charset=utf-8",
      ".svg": "image/svg+xml",
      ".png": "image/png",
      ".jpg": "image/jpeg",
      ".jpeg": "image/jpeg",
      ".webp": "image/webp",
      ".ico": "image/x-icon",
      ".txt": "text/plain; charset=utf-8",
      ".pdf": "application/pdf",
      ".woff": "font/woff",
      ".woff2": "font/woff2",
    }[extname(path)] || "application/octet-stream"
  );
}

/**
 * 组装 /api/config 响应：缓存的公共配置 + Web 专属的请求体上限
 * + 已学习的场记结构 Profile 列表。
 * @returns {Promise<object>}
 */
async function clientConfig() {
  const config = await publicConfigForRequests();
  return {
    ...config,
    upload: {
      ...config.upload,
      maxRequestBytes: settings.maxBodyBytes,
    },
    scenarios: await listScenarios(services),
  };
}

/**
 * 解析并校验 Web 服务端运行参数（监听、超时、并发、Basic Auth 等）。
 * @param {object} env 环境变量
 * @returns {object} 归一化后的设置集合
 * @throws {Error} 配置非法（如认证用户名密码只配了一个）时启动失败
 */
function serverSettings(env) {
  return {
    host: cleanSetting(env.HOST) || "127.0.0.1",
    port: integerSetting(env.PORT, 4173, 0, 65_535, "PORT"),
    maxBodyBytes: maxBodyBytesSetting(env),
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

/**
 * MAX_BODY_MB → 请求体字节上限；导出供 MCP 的 get_config 复用同一契约值。
 * @param {object} env 环境变量
 * @returns {number} 字节数
 */
export function maxBodyBytesSetting(env) {
  return (
    integerSetting(env.MAX_BODY_MB, 80, 20, 200, "MAX_BODY_MB") * 1024 * 1024
  );
}

/**
 * 解析 Basic Auth 配置。
 * @param {object} env 环境变量
 * @returns {{ username: string, password: string } | null} 未配置时返回 null
 * @throws {Error} 用户名与密码只配置了一个时抛错
 */
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

/**
 * 校验 Basic 认证头。
 * @param {object} headers 请求头
 * @param {{ username: string, password: string } | null} expected 认证配置
 * @returns {boolean} 未启用认证时恒为 true
 */
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

// 常数时间比较：先对两侧做 sha256 再 timingSafeEqual，
// 既规避逐字节比较的时序侧信道，也满足等长要求。
function secureEqual(actual, expected) {
  const actualHash = createHash("sha256").update(actual).digest();
  const expectedHash = createHash("sha256").update(expected).digest();
  return timingSafeEqual(actualHash, expectedHash);
}
