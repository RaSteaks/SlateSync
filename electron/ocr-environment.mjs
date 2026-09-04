// Read-only OCR environment snapshot behind the Global Settings detection
// dialog.
//
// The dialog answers two questions before any install action: what does this
// machine look like (OS, architecture, Python), and which local OCR engines
// can already run. Everything here is a probe — no installation, no writes,
// and no provider credential ever crosses the OCR child boundary. All system
// dependencies are injected so node:test can fake spawn/fs without touching a
// real machine, mirroring createPaddleOcrInstaller.
import { spawn as defaultSpawn } from "node:child_process";
import { existsSync as defaultExistsSync } from "node:fs";
import { release as defaultOsRelease } from "node:os";
import { createOcrChildEnvironment } from "../lib/ocr/child-environment.mjs";
import { paddleOcrPublicConfig } from "../lib/ocr/paddleocr.mjs";
import { isPackagedRuntime } from "../lib/ocr/runtime-paths.mjs";
import { visionOcrPublicConfig } from "../lib/ocr/vision.mjs";
import {
  paddleOcrInstallDirectory,
  paddleOcrInstallPath,
  pythonProbeCandidates,
} from "./paddleocr-installer.mjs";

// Keep this aligned with the installer's PADDLEOCR_PYTHON_MISSING guidance.
export const OCR_ENVIRONMENT_MIN_PYTHON = Object.freeze({ major: 3, minor: 10 });
const PYTHON_PROBE_TIMEOUT_MS = 5_000;
const OS_VERSION_PROBE_TIMEOUT_MS = 3_000;
const PYTHON_MISSING_MESSAGE =
  "未找到可用的 Python 3。请先安装 Python 3.10 或更高版本，再重试 PaddleOCR 安装。";

export function createOcrEnvironmentProbe({
  userDataPath,
  // `env` may be a function so Main can pass runtimeEnv() lazily: the probe
  // then observes the same effective environment (persisted global-config
  // overrides included) that the next recognition will use, without holding a
  // stale snapshot from startup time.
  env = process.env,
  platform = process.platform,
  arch = process.arch,
  spawnImpl = defaultSpawn,
  existsImpl = defaultExistsSync,
  osRelease = defaultOsRelease,
} = {}) {
  if (typeof userDataPath !== "string" || !userDataPath.trim()) {
    throw new TypeError("OCR 环境探测需要 Electron userData 路径");
  }

  function resolveEnv() {
    return typeof env === "function" ? env() || {} : env || {};
  }

  function runProbe(command, args, timeoutMs) {
    return new Promise((resolve) => {
      let child;
      try {
        child = spawnImpl(command, args, {
          // Probes never receive provider credentials; only PATH/locale and
          // the OCR runtime keys cross into the child environment.
          stdio: ["ignore", "pipe", "pipe"],
          env: createOcrChildEnvironment(resolveEnv()),
        });
      } catch (error) {
        resolve({ ok: false, output: "", error: error?.message || String(error) });
        return;
      }
      let stdout = "";
      let stderr = "";
      let settled = false;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(result);
      };
      const timer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // The close handler is a no-op once the probe is settled.
        }
        finish({ ok: false, output: "", error: "timeout" });
      }, timeoutMs);
      child.stdout?.on("data", (chunk) => {
        stdout += String(chunk);
      });
      // Older interpreters print the version banner to stderr.
      child.stderr?.on("data", (chunk) => {
        stderr += String(chunk);
      });
      child.on("error", (error) => {
        finish({ ok: false, output: "", error: error?.message || String(error) });
      });
      child.on("close", (code) => {
        finish({
          ok: code === 0,
          output: `${stdout}\n${stderr}`,
          error: code === 0 ? null : `exit code ${code}`,
        });
      });
    });
  }

  async function probeOsVersion() {
    const probe = await runProbe(
      "sw_vers",
      ["-productVersion"],
      OS_VERSION_PROBE_TIMEOUT_MS,
    );
    const version = probe.output
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)[0] || "";
    if (probe.ok && version) return version;
    // os.release() keeps the row populated on unusual macOS images where
    // sw_vers is unavailable; the raw Darwin release is still diagnostic.
    return osRelease();
  }

  async function probePython() {
    const candidates = pythonProbeCandidates(platform);
    const attempted = [];
    let lastError = "";
    let ranButUnparseable = false;
    for (const candidate of candidates) {
      const label = candidate.prefix.length
        ? `${candidate.command} ${candidate.prefix.join(" ")}`
        : candidate.command;
      attempted.push(label);
      const probe = await runProbe(
        candidate.command,
        [...candidate.prefix, "--version"],
        PYTHON_PROBE_TIMEOUT_MS,
      );
      if (!probe.ok) {
        lastError = probe.error;
        continue;
      }
      const parsed = parsePythonVersion(probe.output);
      if (!parsed) {
        ranButUnparseable = true;
        continue;
      }
      return {
        found: true,
        command: label,
        version: parsed.banner,
        meetsMinimum: parsed.major > OCR_ENVIRONMENT_MIN_PYTHON.major ||
          (parsed.major === OCR_ENVIRONMENT_MIN_PYTHON.major &&
            parsed.minor >= OCR_ENVIRONMENT_MIN_PYTHON.minor),
        candidates: attempted,
        error: null,
      };
    }
    return {
      found: false,
      command: "",
      version: "",
      meetsMinimum: null,
      candidates: attempted,
      error: ranButUnparseable
        ? "检测到 Python 解释器，但无法解析版本输出。"
        : PYTHON_MISSING_MESSAGE,
    };
  }

  // Mirrors the interpreter resolution that recognition actually performs:
  // PADDLEOCR_PYTHON wins, then the workspace .venv-paddleocr, and only then
  // does the runtime fall back to auto-discovery ("python3"). The dialog must
  // never present the one-click installer's venv as the effective interpreter
  // when the user pinned their own path in Global Settings.
  function probePaddle(activeEnv) {
    const status = paddleOcrPublicConfig(activeEnv, { autoEnable: false });
    const configuredPythonPath = clean(activeEnv.PADDLEOCR_PYTHON);
    // paddleOcrPublicConfig degrades to the literal "python3" when neither a
    // configured path nor a workspace venv exists; surface that state as
    // auto-discovery instead of a pinned-looking absolute path.
    const autoDiscovery = !configuredPythonPath && !status.available;
    const activePythonPath = autoDiscovery ? "" : status.pythonPath;
    return {
      configuredPythonPath,
      activePythonPath,
      activePythonExists: activePythonPath ? Boolean(existsImpl(activePythonPath)) : null,
    };
  }

  function probeVision(activeEnv, packaged) {
    const status = visionOcrPublicConfig(activeEnv, { autoEnable: false });
    const binaryPath = status.binaryPath || "";
    const binaryExists = Boolean(binaryPath) && Boolean(existsImpl(binaryPath));
    const explicitBinary = Boolean(clean(env.VISIONOCR_BINARY));
    const source = explicitBinary
      ? "explicit"
      : binaryExists
        ? (packaged ? "bundled" : "local-build")
        : "missing";
    return {
      binaryPath,
      binaryExists,
      source,
      // Dev builds without a compiled binary can still produce one on demand
      // when the Swift toolchain responds; that is exactly what
      // visionOcrPublicConfig reports as available.
      swiftToolchain: !binaryExists && Boolean(status.available),
    };
  }

  async function snapshot() {
    const activeEnv = resolveEnv();
    const packaged = isPackagedRuntime(activeEnv);
    const osVersion = platform === "darwin" ? await probeOsVersion() : "";
    const python = await probePython();
    const venvPath = paddleOcrInstallDirectory(userDataPath);
    return {
      platform,
      platformLabel: platformLabelText(platform, osVersion),
      architecture: arch,
      architectureLabel: architectureLabelText(arch, platform),
      packaged,
      python,
      paddle: {
        venvPath,
        pythonPath: paddleOcrInstallPath(userDataPath, platform),
        venvExists: Boolean(existsImpl(venvPath)),
        ...probePaddle(activeEnv),
      },
      vision: probeVision(activeEnv, packaged),
    };
  }

  return { snapshot };
}

function parsePythonVersion(output) {
  const match = /Python\s+(\d+)\.(\d+)(?:\.(\d+))?/.exec(String(output || ""));
  if (!match) return null;
  const major = Number(match[1]);
  const minor = Number(match[2]);
  if (!Number.isInteger(major) || !Number.isInteger(minor)) return null;
  return { major, minor, banner: match[0] };
}

function platformLabelText(platform, osVersion) {
  if (platform === "darwin") return osVersion ? `macOS ${osVersion}` : "macOS";
  if (platform === "win32") return "Windows";
  if (platform === "linux") return "Linux";
  return platform;
}

function architectureLabelText(arch, platform) {
  if (platform === "darwin" && arch === "arm64") return "Apple Silicon（arm64）";
  if (platform === "darwin" && arch === "x64") return "Intel（x64）";
  return arch;
}

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}
