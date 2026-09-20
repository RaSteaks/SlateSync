import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPOSITORY_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const PACKAGE_VERSION = JSON.parse(
  readFileSync(join(REPOSITORY_ROOT, "package.json"), "utf8"),
).version;

// CI must receive both the signing material and Apple notarization credentials;
// failing before electron-builder prevents an accidental ad hoc release.
const CI_SIGNING_VARIABLES = Object.freeze([
  "CSC_LINK",
  "CSC_KEY_PASSWORD",
  "CSC_NAME",
  "APPLE_ID",
  "APPLE_APP_SPECIFIC_PASSWORD",
  "APPLE_TEAM_ID",
]);

function commandOutput(result) {
  return `${result?.stdout || ""}\n${result?.stderr || ""}`.trim();
}

function runCommand(run, command, args) {
  const result = run(command, args, {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return {
    ...result,
    output: commandOutput(result),
  };
}

function summarize(detail) {
  if (!detail) return "未知错误";
  if (detail.length <= 700) return detail;
  return `${detail.slice(0, 350)} … ${detail.slice(-350)}`;
}

function requireSuccessful(result, label) {
  if (result?.error || result?.status !== 0) {
    throw new Error(`[SlateSync] ${label}失败：${summarize(result?.output || result?.error?.message)}`);
  }
  return result;
}

function requireNonEmptyEnvironment(env, names) {
  const missing = names.filter((name) => !String(env[name] || "").trim());
  if (missing.length > 0) {
    throw new Error(`[SlateSync] 缺少 macOS 发布签名变量：${missing.join(", ")}。`);
  }
}

export function preflightMacSigning({
  platform = process.platform,
  env = process.env,
  run = spawnSync,
  ci = false,
} = {}) {
  if (platform !== "darwin") {
    throw new Error("[SlateSync] macOS 签名预检只能在 macOS 主机上运行。");
  }

  const identityName = String(env.CSC_NAME || "").trim();
  if (identityName && !identityName.startsWith("Developer ID Application:")) {
    throw new Error("[SlateSync] CSC_NAME 必须是 Developer ID Application 身份。");
  }

  if (ci) {
    requireNonEmptyEnvironment(env, CI_SIGNING_VARIABLES);
    const expectedTag = `v${PACKAGE_VERSION}-electron`;
    if (env.GITHUB_REF_NAME && env.GITHUB_REF_NAME !== expectedTag) {
      throw new Error(`[SlateSync] Release tag 与 package.json 版本不一致：期望 ${expectedTag}，实际 ${env.GITHUB_REF_NAME}。`);
    }
    return {
      mode: "ci",
      version: PACKAGE_VERSION,
      identityName,
      tag: env.GITHUB_REF_NAME || null,
    };
  }

  if (String(env.CSC_LINK || "").trim()) {
    // A linked certificate is imported by electron-builder, so local preflight
    // uses CSC_NAME to keep the selected identity explicit and auditable.
    if (!identityName) {
      throw new Error("[SlateSync] 使用 CSC_LINK 时必须同时设置 CSC_NAME，以锁定 Developer ID Application 身份。");
    }
    return {
      mode: "linked-certificate",
      version: PACKAGE_VERSION,
      identityName,
    };
  }

  const identities = runCommand(run, "security", ["find-identity", "-v", "-p", "codesigning"]);
  requireSuccessful(identities, "读取本机代码签名身份");
  if (!/Developer ID Application:\s+[^\n]+/u.test(identities.output)) {
    throw new Error("[SlateSync] 本机没有可用的 Developer ID Application 身份。");
  }
  if (identityName && !identities.output.includes(identityName)) {
    throw new Error(`[SlateSync] CSC_NAME 不在本机有效身份中：${identityName}`);
  }

  return {
    mode: "keychain",
    version: PACKAGE_VERSION,
    identityName,
  };
}

export function appPathForArchitecture(architecture, distRoot = join(REPOSITORY_ROOT, "dist")) {
  if (architecture === "arm64") return join(distRoot, "mac-arm64", "SlateSync.app");
  if (architecture === "x64") return join(distRoot, "mac", "SlateSync.app");
  throw new Error(`[SlateSync] 不支持的 macOS 应用架构：${architecture}。`);
}

export function verifyMacSignedApp({
  appPath,
  expectedVersion = PACKAGE_VERSION,
  requireNotarization = false,
  platform = process.platform,
  env = process.env,
  run = spawnSync,
} = {}) {
  if (platform !== "darwin") {
    throw new Error("[SlateSync] macOS 签名验证只能在 macOS 主机上运行。");
  }
  if (!appPath || !existsSync(appPath)) {
    throw new Error(`[SlateSync] 找不到待验证的 macOS 应用：${appPath || "未提供路径"}`);
  }

  const infoPlist = join(appPath, "Contents", "Info.plist");
  const versionResult = requireSuccessful(
    runCommand(run, "plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", infoPlist]),
    "读取应用版本",
  );
  const actualVersion = versionResult.stdout.trim();
  if (actualVersion !== expectedVersion) {
    throw new Error(`[SlateSync] 应用版本不匹配：期望 ${expectedVersion}，实际 ${actualVersion || "未知"}。`);
  }

  const signature = runCommand(run, "codesign", ["-dvvv", "--entitlements", ":-", appPath]);
  // Displaying the signature first gives release failures a useful identity
  // and hardened-runtime diagnosis before strict nested-code verification.
  if (signature.status !== 0 || /code object is not signed at all|Signature=adhoc|TeamIdentifier=not set/u.test(signature.output)) {
    throw new Error(`[SlateSync] 应用不是可发布的 Developer ID 签名：${summarize(signature.output)}`);
  }
  if (!/Authority=Developer ID Application:/u.test(signature.output)) {
    throw new Error("[SlateSync] 应用签名身份不是 Developer ID Application。");
  }
  if (!/flags=.*\bruntime\b/u.test(signature.output)) {
    throw new Error("[SlateSync] 应用签名未启用 hardened runtime。");
  }

  const expectedIdentity = String(env.CSC_NAME || "").trim();
  if (expectedIdentity && !signature.output.includes(expectedIdentity)) {
    throw new Error(`[SlateSync] 产物签名身份与 CSC_NAME 不一致：${expectedIdentity}`);
  }

  requireSuccessful(
    runCommand(run, "codesign", ["--verify", "--deep", "--strict", "--verbose=4", appPath]),
    "验证嵌套代码签名",
  );

  if (requireNotarization) {
    requireSuccessful(
      runCommand(run, "spctl", ["--assess", "--type", "execute", "-vv", appPath]),
      "验证 Gatekeeper 评估",
    );
    requireSuccessful(
      runCommand(run, "xcrun", ["stapler", "validate", appPath]),
      "验证 notarization ticket",
    );
  }

  return {
    appPath,
    version: actualVersion,
    notarized: requireNotarization,
  };
}

function parseArguments(args) {
  const [mode, ...rest] = args;
  const options = {
    mode,
    ci: rest.includes("--ci"),
    notarized: rest.includes("--notarized"),
    all: rest.includes("--all"),
    app: null,
    arch: null,
  };
  for (let index = 0; index < rest.length; index += 1) {
    if (rest[index] === "--app") options.app = rest[++index];
    if (rest[index] === "--arch") options.arch = rest[++index];
  }
  return options;
}

function runCli(args) {
  const options = parseArguments(args);
  if (options.mode === "preflight") {
    const result = preflightMacSigning({ ci: options.ci });
    console.log(`[SlateSync] macOS 签名预检通过：${result.mode}，版本 ${result.version}`);
    return;
  }
  if (options.mode !== "verify") {
    throw new Error("用法：node scripts/macos-signing.mjs preflight [--ci] | verify (--app PATH | --arch arm64|x64 | --all) [--notarized]");
  }

  const appPaths = options.app
    ? [options.app]
    : options.arch
      ? [appPathForArchitecture(options.arch)]
      : options.all
        ? [appPathForArchitecture("arm64"), appPathForArchitecture("x64")]
        : [];
  if (appPaths.length === 0) {
    throw new Error("[SlateSync] verify 需要 --app、--arch 或 --all。");
  }
  for (const appPath of appPaths) {
    const result = verifyMacSignedApp({ appPath, requireNotarization: options.notarized });
    console.log(`[SlateSync] macOS 签名验证通过：${result.appPath}，版本 ${result.version}`);
  }
}

const invokedDirectly = process.argv[1]
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
