export async function readRecognitionResponse(response, onProgress) {
  const contentType = response.headers.get("content-type") || "";
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response));
  }

  if (!contentType.includes("application/x-ndjson")) {
    const data = await response.json();
    if (data?.error) throw new Error(data.error);
    return data;
  }

  if (!response.body?.getReader) {
    return parseRecognitionNdjson(await response.text(), onProgress);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let result;
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
      const parsed = consumeLines(buffer, onProgress);
      buffer = parsed.remainder;
      if (parsed.result !== undefined) result = parsed.result;
      if (done) break;
    }
    if (buffer.trim()) {
      const parsed = parseEventLine(buffer, onProgress);
      if (parsed !== undefined) result = parsed;
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  }

  if (result === undefined) {
    throw new Error("识别连接已结束，但服务器没有返回最终结果");
  }
  return result;
}

export function parseRecognitionNdjson(value, onProgress) {
  const parsed = consumeLines(`${String(value || "")}\n`, onProgress);
  if (parsed.result === undefined) {
    throw new Error("识别连接已结束，但服务器没有返回最终结果");
  }
  return parsed.result;
}

function consumeLines(value, onProgress) {
  const lines = value.split(/\r?\n/);
  const remainder = lines.pop() || "";
  let result;
  for (const line of lines) {
    if (!line.trim()) continue;
    const parsed = parseEventLine(line, onProgress);
    if (parsed !== undefined) result = parsed;
  }
  return { remainder, result };
}

function parseEventLine(line, onProgress) {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    throw new Error("识别服务器返回了无法解析的进度数据");
  }
  if (!event || typeof event !== "object") {
    throw new Error("识别服务器返回了无效的进度数据");
  }
  if (event.type === "error") {
    throw new Error(event.error || "识别失败");
  }
  if (event.type === "result") return event.data;
  if (event.type === "progress" && typeof onProgress === "function") {
    try {
      onProgress(event);
    } catch {
      // Rendering progress is advisory and cannot invalidate a valid result.
    }
  }
  return undefined;
}

async function responseErrorMessage(response) {
  const raw = await response.text();
  if (!raw) return `识别请求失败（HTTP ${response.status}）`;
  try {
    const data = JSON.parse(raw);
    return data.error || data.message || `识别请求失败（HTTP ${response.status}）`;
  } catch {
    return `识别请求失败（HTTP ${response.status}）`;
  }
}
