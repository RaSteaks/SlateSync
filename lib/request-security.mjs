export function validateApiRequest(headers) {
  const contentType = String(headers["content-type"] || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw httpError("接口只接受 application/json", 415);
  }

  const fetchSite = String(headers["sec-fetch-site"] || "").toLowerCase();
  if (fetchSite && fetchSite !== "same-origin" && fetchSite !== "none") {
    throw httpError("禁止跨站调用本机 API", 403);
  }

  const origin = headers.origin;
  const host = headers.host;
  if (origin && !sameHostOrigin(origin, host)) {
    throw httpError("请求来源与 SlateSync 服务不一致", 403);
  }
}

function sameHostOrigin(origin, host) {
  if (!host) return false;
  try {
    const parsed = new URL(origin);
    return ["http:", "https:"].includes(parsed.protocol) && parsed.host === host;
  } catch {
    return false;
  }
}

function httpError(message, status) {
  const error = new Error(message);
  error.status = status;
  return error;
}
