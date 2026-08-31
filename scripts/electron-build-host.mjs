import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);

const hostTargets = Object.freeze({
  darwin: Object.freeze({ label: "macOS", builderFlag: "--mac" }),
  win32: Object.freeze({ label: "Windows", builderFlag: "--win" }),
});
const platformFlags = new Map([
  ["--mac", "darwin"],
  ["--macos", "darwin"],
  ["-m", "darwin"],
  ["-o", "darwin"],
  ["--win", "win32"],
  ["--windows", "win32"],
  ["-w", "win32"],
  ["--linux", "linux"],
  ["-l", "linux"],
]);
const unsupportedArchitectureFlags = new Set(["--ia32", "--x86", "--armv7l"]);

function requestedPlatforms(argument) {
  const flag = argument.split("=", 1)[0];
  const directPlatform = platformFlags.get(flag);
  if (directPlatform) {
    return [directPlatform];
  }

  // electron-builder also accepts compact short options such as -mwl;
  // inspect every platform alias so a combined flag cannot cross the guard.
  if (flag.startsWith("-") && !flag.startsWith("--")) {
    const compactPlatforms = [...flag.slice(1)].map((alias) => platformFlags.get(`-${alias}`));
    if (compactPlatforms.every(Boolean)) {
      return compactPlatforms;
    }
  }
  return [];
}

export function resolveHostTarget(platform) {
  // Limit lookup to declared host platforms; inherited Object members are not targets.
  const target = Object.hasOwn(hostTargets, platform) ? hostTargets[platform] : undefined;
  if (!target) {
    throw new Error("[SlateSync] 当前只支持在 macOS 或 Windows 主机上打包。");
  }
  return target;
}

export function buildHostArguments(platform, args = []) {
  const target = resolveHostTarget(platform);
  for (const argument of args) {
    const flag = argument.split("=", 1)[0];
    for (const requestedPlatform of requestedPlatforms(argument)) {
      if (requestedPlatform !== platform) {
        throw new Error(
          `[SlateSync] ${target.label} 主机不能生成 ${requestedPlatform} 包；请只使用当前宿主平台目标。`,
        );
      }
    }
    if (unsupportedArchitectureFlags.has(flag)) {
      throw new Error(`[SlateSync] 不支持的 Windows ia32/x86/armv7l 打包参数：${argument}。`);
    }
    if (platform === "win32" && ["--arm64", "--universal"].includes(flag)) {
      throw new Error(`[SlateSync] Windows 打包固定使用 x64，不支持参数：${argument}。`);
    }
  }

  // The Windows config and explicit flag both pin local source builds to x64;
  // this prevents a 32-bit installer from returning through host defaults.
  const architecture = platform === "win32"
    && !args.some((argument) => argument === "--x64" || argument.startsWith("--x64="))
    ? ["--x64"]
    : [];
  return [target.builderFlag, ...architecture, ...args];
}

export function runHostPackaging({
  platform = process.platform,
  args = process.argv.slice(2),
  spawn = spawnSync,
} = {}) {
  const builderArgs = buildHostArguments(platform, args);
  const electronBuilderCli = require.resolve("electron-builder/cli.js");
  const result = spawn(process.execPath, [electronBuilderCli, ...builderArgs], {
    stdio: "inherit",
  });

  if (result.error) {
    throw new Error(`[SlateSync] 无法启动 electron-builder：${result.error.message}`);
  }
  return result.status ?? 1;
}

// Keep imports testable while making direct execution behave exactly like an
// npm packaging command, including the host-platform guard above.
const invokedDirectly = process.argv[1]
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  try {
    process.exitCode = runHostPackaging();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
