import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildVisionOcr } from "./build-vision-ocr.mjs";
import { assertMacOSPlatform } from "../lib/macos-platform-guard.mjs";

const require = createRequire(import.meta.url);

const macOSTarget = Object.freeze({ label: "macOS", builderFlag: "--mac" });
const macOSPlatformFlags = new Set(["--mac", "--macos", "-m", "-o"]);
const rejectedPlatformFlags = new Map([
  ["--win", "win32"],
  ["--windows", "win32"],
  ["-w", "win32"],
  ["--linux", "linux"],
  ["-l", "linux"],
]);
const unsupportedArchitectureFlags = new Set(["--ia32", "--x86", "--armv7l"]);

function rejectedPlatforms(argument) {
  const flag = argument.split("=", 1)[0];
  if (macOSPlatformFlags.has(flag)) return [];
  const directPlatform = rejectedPlatformFlags.get(flag);
  if (directPlatform) return [directPlatform];

  // electron-builder accepts compact short options such as -mwl. Inspect only
  // rejected aliases so a combined flag cannot smuggle in another target.
  if (flag.startsWith("-") && !flag.startsWith("--")) {
    return [...flag.slice(1)]
      .map((alias) => rejectedPlatformFlags.get(`-${alias}`))
      .filter(Boolean);
  }
  return [];
}

export function resolveHostTarget(platform) {
  assertMacOSPlatform(platform);
  return macOSTarget;
}

export function buildHostArguments(platform, args = []) {
  resolveHostTarget(platform);
  for (const argument of args) {
    const flag = argument.split("=", 1)[0];
    for (const rejectedPlatform of rejectedPlatforms(argument)) {
      throw new Error(
        `[SlateSync] 当前仅允许 macOS 目标；拒绝 ${rejectedPlatform} 打包参数：${argument}。`,
      );
    }
    if (unsupportedArchitectureFlags.has(flag)) {
      throw new Error(`[SlateSync] macOS 当前打包不支持该架构参数：${argument}。`);
    }
  }

  // The wrapper always supplies the macOS selector so a local command cannot
  // fall back to electron-builder's host-dependent default target.
  return [macOSTarget.builderFlag, ...args];
}

export function visionBridgeArchitecture(platform, args = []) {
  assertMacOSPlatform(platform);
  const universal = args.includes("--universal");
  const arm64 = args.includes("--arm64");
  const x64 = args.includes("--x64");
  // When both thin package targets are requested, one bridge must serve both
  // slices; compiling only the first flag would leave the second app unusable.
  if (universal || (arm64 && x64)) return "universal";
  if (arm64) return "arm64";
  if (x64) return "x64";
  // The builder's macOS default contains both architectures, so the bridge
  // must be universal when no explicit target narrows the package.
  return "universal";
}

export function runHostPackaging({
  platform = process.platform,
  args = process.argv.slice(2),
  spawn = spawnSync,
  buildBridge = buildVisionOcr,
  resolveBuilderCli = () => require.resolve("electron-builder/cli.js"),
} = {}) {
  const builderArgs = buildHostArguments(platform, args);
  buildBridge({
    platform,
    architecture: visionBridgeArchitecture(platform, args),
  });
  const electronBuilderCli = resolveBuilderCli();
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
