// Renderer HMR is a development-only capability, but its BrowserWindow still
// exposes SlateSync's typed Preload. Keep every accepted URL on loopback so a
// remote page can never inherit that local application gateway.
const LOOPBACK_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

export function parseRendererDevUrl(value) {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (
      url.protocol !== "http:"
      || !LOOPBACK_HOSTNAMES.has(url.hostname)
      || url.username
      || url.password
    ) {
      return null;
    }
    return { href: url.href, origin: url.origin };
  } catch {
    return null;
  }
}

export function isAllowedRendererDevNavigation(value, expectedOrigin) {
  const target = parseRendererDevUrl(value);
  return Boolean(target && expectedOrigin && target.origin === expectedOrigin);
}
