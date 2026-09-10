// Environment policy for local OCR subprocesses.
//
// Main keeps provider credentials in its process environment so model
// requests can resolve them. OCR workers do not need those credentials, so
// they receive a deliberately selected environment instead of a spread copy.
const BASE_ENV_KEYS = Object.freeze([
  "PATH",
  "Path",
  "HOME",
  "USERPROFILE",
  "APPDATA",
  "LOCALAPPDATA",
  "TMPDIR",
  "TEMP",
  "TMP",
  "SYSTEMROOT",
  "WINDIR",
  "LANG",
  "LC_ALL",
  "LANGUAGE",
]);

const RUNTIME_ENV_KEYS = Object.freeze([
  "SLATESYNC_PROJECT_DIR",
  "SLATESYNC_PACKAGED",
  "PADDLE_PDX_CACHE_HOME",
]);

// Package installation may need pip's configured mirror and certificate
// settings. Runtime inference intentionally omits the PIP_* group because
// mirror URLs can themselves contain credentials and are not needed by OCR.
const PACKAGE_NETWORK_ENV_KEYS = Object.freeze([
  "PIP_INDEX_URL",
  "PIP_EXTRA_INDEX_URL",
  "PIP_TRUSTED_HOST",
  "PIP_CERT",
]);

const NETWORK_ENV_KEYS = Object.freeze([
  "HTTPS_PROXY",
  "HTTP_PROXY",
  "NO_PROXY",
  "REQUESTS_CA_BUNDLE",
  "SSL_CERT_FILE",
]);

/**
 * Build the minimal environment accepted by an OCR child process.
 *
 * The overrides object is reserved for fixed, non-secret runtime values
 * selected by the caller, such as the Paddle cache path and output flags.
 */
export function createOcrChildEnvironment(
  source = process.env,
  { includePackageNetwork = false, overrides = {} } = {},
) {
  const childEnv = {};
  const keys = [
    ...BASE_ENV_KEYS,
    ...RUNTIME_ENV_KEYS,
    ...NETWORK_ENV_KEYS,
    ...(includePackageNetwork ? PACKAGE_NETWORK_ENV_KEYS : []),
  ];
  for (const key of keys) {
    const value = source?.[key] ?? process.env[key];
    if (value !== undefined) childEnv[key] = value;
  }

  // Windows commonly exposes PATH as Path; keeping both spellings lets
  // Python resolve helper commands without copying arbitrary environment keys.
  if (childEnv.PATH && !childEnv.Path) childEnv.Path = childEnv.PATH;
  if (childEnv.Path && !childEnv.PATH) childEnv.PATH = childEnv.Path;

  return {
    ...childEnv,
    ...overrides,
  };
}

