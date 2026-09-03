import { existsSync, mkdirSync, rmSync, statSync, mkdtempSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { assertMacOSPlatform } from "../lib/macos-platform-guard.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = resolve(SCRIPT_DIR, "..");
const SOURCE_PATH = join(REPOSITORY_ROOT, "scripts", "vision_ocr.swift");
const OUTPUT_PATH = join(REPOSITORY_ROOT, "bin", "vision-ocr");
const ARCHITECTURES = Object.freeze({
  arm64: "arm64-apple-macos13",
  x64: "x86_64-apple-macos13",
});

export function normalizeVisionArchitecture(value = "universal") {
  const normalized = String(value).trim().toLowerCase();
  if (normalized === "x86_64") return "x64";
  if (normalized === "arm64" || normalized === "x64" || normalized === "universal") {
    return normalized;
  }
  throw new Error(`[SlateSync] 不支持的 Vision OCR 架构：${value}。`);
}

export function visionArchitectureFromArgs(args = []) {
  const inline = args.find((argument) => argument.startsWith("--arch="));
  const separateIndex = args.indexOf("--arch");
  const value = inline
    ? inline.slice("--arch=".length)
    : separateIndex >= 0
      ? args[separateIndex + 1]
      : "universal";
  if (separateIndex >= 0 && !value) {
    throw new Error("[SlateSync] --arch 需要 arm64、x64 或 universal。");
  }
  return normalizeVisionArchitecture(value);
}

function runChecked(runCommand, command, args, label) {
  const result = runCommand(command, args, {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result?.error || result?.status !== 0) {
    const detail = String(result?.stderr || result?.stdout || result?.error?.message || "未知错误").trim();
    throw new Error(`[SlateSync] ${label}失败：${summarizeCommandError(detail)}`);
  }
  return result;
}

function summarizeCommandError(detail) {
  if (!detail) return "未知错误";
  if (detail.length <= 700) return detail;
  // Keep both the compiler's root cause and its final context; Swift often
  // emits a long module-import trace whose useful first line is easy to lose.
  return `${detail.slice(0, 350)} … ${detail.slice(-350)}`;
}

function compileThinBinary(runCommand, architecture, outputPath) {
  runChecked(
    runCommand,
    "xcrun",
    ["swiftc", "-O", "-target", ARCHITECTURES[architecture], "-o", outputPath, SOURCE_PATH],
    `Vision OCR ${architecture} 编译`,
  );
}

export function verifyVisionOcrBinary({
  binaryPath = OUTPUT_PATH,
  architecture = "universal",
  runCommand = spawnSync,
} = {}) {
  const expectedArchitecture = normalizeVisionArchitecture(architecture);
  if (!existsSync(binaryPath)) {
    throw new Error(`[SlateSync] Vision OCR bridge 未生成：${binaryPath}`);
  }
  if ((statSync(binaryPath).mode & 0o111) === 0) {
    throw new Error(`[SlateSync] Vision OCR bridge 不可执行：${binaryPath}`);
  }

  const archResult = runChecked(
    runCommand,
    "lipo",
    ["-archs", binaryPath],
    "Vision OCR 架构验证",
  );
  const actualArchitectures = String(archResult.stdout || "").trim().split(/\s+/).filter(Boolean).sort();
  const expectedArchitectures = expectedArchitecture === "universal"
    ? ["arm64", "x86_64"]
    : [expectedArchitecture === "x64" ? "x86_64" : "arm64"];
  if (JSON.stringify(actualArchitectures) !== JSON.stringify([...expectedArchitectures].sort())) {
    throw new Error(
      `[SlateSync] Vision OCR 架构不匹配：期望 ${expectedArchitectures.join("+")}，实际 ${actualArchitectures.join("+") || "未知"}。`,
    );
  }

  const checkResult = runChecked(
    runCommand,
    binaryPath,
    ["--check"],
    "Vision OCR 运行验证",
  );
  const output = `${checkResult.stdout || ""}\n${checkResult.stderr || ""}`;
  const marker = "__SLATESYNC_OCR_JSON__";
  const markerIndex = output.indexOf(marker);
  if (markerIndex < 0) {
    throw new Error("[SlateSync] Vision OCR --check 未返回可识别的 JSON 响应。");
  }
  let payload;
  try {
    const line = output.slice(markerIndex + marker.length).split(/\r?\n/, 1)[0];
    payload = JSON.parse(line);
  } catch (error) {
    throw new Error(`[SlateSync] Vision OCR --check 返回了无效 JSON：${error.message}`);
  }
  if (payload?.ok !== true) {
    throw new Error(`[SlateSync] Vision OCR --check 未通过：${payload?.error?.message || "未知错误"}`);
  }
  return {
    binaryPath,
    architecture: expectedArchitecture,
    actualArchitectures,
    check: payload,
  };
}

export function buildVisionOcr({
  platform = process.platform,
  architecture = "universal",
  runCommand = spawnSync,
  outputPath = OUTPUT_PATH,
} = {}) {
  // A successful no-op here would let a non-macOS caller appear to have
  // produced a valid package, so reject the obsolete platform path explicitly.
  assertMacOSPlatform(platform);
  const targetArchitecture = normalizeVisionArchitecture(architecture);
  if (!existsSync(SOURCE_PATH)) {
    throw new Error(`[SlateSync] 缺少 Vision OCR 源文件：${SOURCE_PATH}`);
  }
  mkdirSync(dirname(outputPath), { recursive: true });

  if (targetArchitecture === "universal") {
    const tempDirectory = mkdtempSync(join(tmpdir(), "slatesync-vision-"));
    try {
      const armPath = join(tempDirectory, "vision-ocr-arm64");
      const x64Path = join(tempDirectory, "vision-ocr-x64");
      compileThinBinary(runCommand, "arm64", armPath);
      compileThinBinary(runCommand, "x64", x64Path);
      runChecked(
        runCommand,
        "lipo",
        ["-create", "-output", outputPath, armPath, x64Path],
        "Vision OCR universal 合并",
      );
    } finally {
      rmSync(tempDirectory, { recursive: true, force: true });
    }
  } else {
    compileThinBinary(runCommand, targetArchitecture, outputPath);
  }

  return {
    skipped: false,
    ...verifyVisionOcrBinary({ binaryPath: outputPath, architecture: targetArchitecture, runCommand }),
  };
}

const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  try {
    const architecture = visionArchitectureFromArgs(process.argv.slice(2));
    const result = buildVisionOcr({ architecture });
    console.log(`[SlateSync] Vision OCR bridge 已验证：${result.actualArchitectures.join("+")}`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
