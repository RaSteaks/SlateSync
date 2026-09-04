// App-assisted PaddleOCR setup.
//
// The packaged application contains the runner and its pinned requirements,
// but the App bundle is not a writable installation target. This module keeps
// the user-owned Python environment under Electron's userData directory and
// reports coarse, truthful stages so both Renderers can show one stable flow.
import { spawn as defaultSpawn } from "node:child_process";
import { lstat, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { createOcrChildEnvironment } from "../lib/ocr/child-environment.mjs";
import { runtimeProjectDir } from "../lib/ocr/runtime-paths.mjs";

export const PADDLEOCR_INSTALL_CANCEL_CODE = "PADDLEOCR_INSTALL_CANCELED";
export const PADDLEOCR_INSTALL_STAGES = Object.freeze([
  "detect-python",
  "create-environment",
  "install-dependencies",
  "verify",
  "completed",
]);

const INSTALL_DIRECTORY_NAME = "paddleocr-venv";
const INSTALL_COMMAND_TIMEOUT_MS = 30 * 60 * 1000;
const REQUIRED_PACKAGES = ["paddlepaddle", "paddleocr"];

/** Return the stable, writable venv location used by packaged and dev builds. */
export function paddleOcrInstallDirectory(userDataPath) {
  return join(userDataPath, INSTALL_DIRECTORY_NAME);
}

export function paddleOcrInstallPath(userDataPath, platform = process.platform) {
  const pythonDirectory = paddleOcrInstallDirectory(userDataPath);
  return platform === "win32"
    ? join(pythonDirectory, "Scripts", "python.exe")
    : join(pythonDirectory, "bin", "python");
}

/** Interpreter aliases probed in order; shared by the installer and the
 * read-only environment snapshot so the two can never drift. */
export function pythonProbeCandidates(platform = process.platform) {
  return platform === "win32"
    ? [
      { command: "py", prefix: ["-3"] },
      { command: "python", prefix: [] },
      { command: "python3", prefix: [] },
    ]
    : [
      { command: "python3", prefix: [] },
      { command: "python", prefix: [] },
    ];
}

/**
 * Create one serialized installer instance for the application lifetime.
 * Dependencies are injected so the state machine can be tested without
 * downloading packages or mutating a real user's Python installation.
 */
export function createPaddleOcrInstaller({
  userDataPath,
  env = process.env,
  platform = process.platform,
  checkOcr,
  spawnImpl = defaultSpawn,
  readFileImpl = readFile,
  mkdirImpl = mkdir,
  lstatImpl = lstat,
  runCommand: injectedRunCommand,
} = {}) {
  if (typeof userDataPath !== "string" || !userDataPath.trim()) {
    throw new TypeError("PaddleOCR 安装器需要 Electron userData 路径");
  }
  if (typeof checkOcr !== "function") {
    throw new TypeError("PaddleOCR 安装器需要 Main 侧 OCR 检查器");
  }

  let activeOperation = null;

  async function install({ env: installEnv = env, onProgress } = {}) {
    if (activeOperation) {
      const busy = new Error("PaddleOCR 安装正在进行中，请等待当前安装结束。");
      busy.code = "PADDLEOCR_INSTALL_BUSY";
      throw busy;
    }

    const operation = {
      cancelRequested: false,
      child: null,
      killTimer: null,
      // Verification owns its own Python child, so cancellation must travel
      // through an AbortSignal even when the installer has no active command.
      controller: new AbortController(),
    };
    activeOperation = operation;

    try {
      return await runInstall({
        operation,
        installEnv,
        onProgress,
      });
    } finally {
      clearKillTimer(operation);
      if (activeOperation === operation) activeOperation = null;
    }
  }

  function cancel() {
    const operation = activeOperation;
    if (!operation) return { canceled: false };
    operation.cancelRequested = true;
    operation.controller.abort();
    if (operation.child && typeof operation.child.kill === "function") {
      try {
        operation.child.kill("SIGTERM");
      } catch {
        // The child may already have exited; the command completion path owns
        // the final cancellation result and will clear the active operation.
      }
      operation.killTimer = setTimeout(() => {
        if (operation.child && typeof operation.child.kill === "function") {
          try {
            operation.child.kill("SIGKILL");
          } catch {
            // A closed process is already in the desired terminal state.
          }
        }
      }, 2_000);
    }
    return { canceled: true };
  }

  async function runInstall({ operation, installEnv, onProgress }) {
    const projectDir = runtimeProjectDir(installEnv);
    const requirementsPath = join(projectDir, "requirements-ocr.txt");
    let requirements;
    try {
      requirements = await readFileImpl(requirementsPath, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") {
        const missing = new Error("当前安装包缺少 PaddleOCR 依赖清单，请重新下载或重新打包 SlateSync。");
        missing.code = "PADDLEOCR_REQUIREMENTS_MISSING";
        throw missing;
      }
      throw error;
    }
    assertRequirements(requirements, requirementsPath);
    throwIfCanceled(operation);

    emitProgress(onProgress, {
      stage: "detect-python",
      percent: 5,
      message: "正在检查本机 Python 环境…",
    });
    const python = await findPython({
      operation,
      projectDir,
      env: installEnv,
    });

    const pythonPath = paddleOcrInstallPath(userDataPath, platform);
    const venvPath = paddleOcrInstallDirectory(userDataPath);
    await assertInstallDirectoryCanBeUsed(venvPath, lstatImpl);
    await mkdirImpl(userDataPath, { recursive: true });
    throwIfCanceled(operation);

    emitProgress(onProgress, {
      stage: "create-environment",
      percent: 20,
      message: "已找到 Python，正在创建独立运行环境…",
    });
    await runCommand(
      python,
      ["-m", "venv", venvPath],
      { operation, projectDir, env: childEnvironment(installEnv) },
    );

    emitProgress(onProgress, {
      stage: "install-dependencies",
      percent: 35,
      message: "正在安装 PaddleOCR 依赖，首次安装可能需要几分钟…",
    });
    // Use the interpreter created inside the target venv for every pip call.
    // Reusing the system `python3` (or Windows `py -3`) would install packages
    // outside the environment that the OCR runner is going to verify.
    await runCommand(
      pythonPath,
      ["-m", "pip", "install", "--upgrade", "pip"],
      { operation, projectDir, env: childEnvironment(installEnv) },
    );
    await runCommand(
      pythonPath,
      ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "-r", requirementsPath],
      { operation, projectDir, env: childEnvironment(installEnv) },
    );

    emitProgress(onProgress, {
      stage: "verify",
      percent: 90,
      message: "依赖已安装，正在验证 PaddleOCR…",
    });
    throwIfCanceled(operation);
    const checkResult = await runCheckWithCancellation({
      operation,
      pythonPath,
      env: childEnvironment(installEnv),
    });
    throwIfCanceled(operation);
    if (!checkResult?.ok) {
      const verificationError = new Error(
        checkResult?.error?.message || "PaddleOCR 验证失败。",
      );
      verificationError.code = checkResult?.error?.code || "PADDLEOCR_VERIFY_FAILED";
      throw verificationError;
    }

    emitProgress(onProgress, {
      stage: "completed",
      percent: 100,
      message: "PaddleOCR 已安装并验证通过。",
    });
    return {
      pythonPath,
      paddleVersion: String(checkResult.paddleVersion || "unknown"),
      paddleOcrVersion: String(checkResult.paddleOcrVersion || "unknown"),
    };
  }

  function runCheckWithCancellation({ operation, ...request }) {
    const signal = operation.controller.signal;
    if (signal.aborted) return Promise.reject(canceledError());

    return new Promise((resolve, reject) => {
      let settled = false;
      const cleanup = () => signal.removeEventListener("abort", onAbort);
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        cleanup();
        callback(value);
      };
      const onAbort = () => finish(reject, canceledError());
      signal.addEventListener("abort", onAbort, { once: true });

      let checkPromise;
      try {
        // The built-in checker terminates its Python child with this signal;
        // the outer race also protects the installer from an injected or
        // future checker that forgets to observe cancellation.
        checkPromise = Promise.resolve(checkOcr({ ...request, signal }));
      } catch (error) {
        finish(reject, error);
        return;
      }
      checkPromise.then(
        (value) => finish(resolve, value),
        (error) => finish(reject, error),
      );
      if (signal.aborted) onAbort();
    });
  }

  async function findPython({ operation, projectDir, env: candidateEnv }) {
    for (const candidate of pythonProbeCandidates(platform)) {
      try {
        await runCommand(
          candidate,
          ["--version"],
          { operation, projectDir, env: childEnvironment(candidateEnv) },
        );
        return candidate;
      } catch (error) {
        if (isInstallCanceled(error, operation)) throw canceledError();
        // A missing or unusable alias is expected while probing the next one.
      }
    }
    const missing = new Error("未找到可用的 Python 3。请先安装 Python 3.10 或更高版本，再重试 PaddleOCR 安装。");
    missing.code = "PADDLEOCR_PYTHON_MISSING";
    throw missing;
  }

  async function runCommand(commandSpec, args, options) {
    throwIfCanceled(options.operation);
    if (typeof injectedRunCommand === "function") {
      const result = await injectedRunCommand(commandSpec, args, options);
      throwIfCanceled(options.operation);
      assertCommandResult(commandSpec, result);
      return result;
    }
    const command = typeof commandSpec === "string" ? commandSpec : commandSpec.command;
    const prefix = typeof commandSpec === "string" ? [] : commandSpec.prefix;
    const result = await runProcess(
      command,
      [...prefix, ...args],
      {
        ...options,
        cwd: options.projectDir,
        operation: options.operation,
        spawnImpl,
        timeoutMs: INSTALL_COMMAND_TIMEOUT_MS,
      },
    );
    assertCommandResult(commandSpec, result);
    return result;
  }

  return {
    install,
    cancel,
    isInstalling: () => Boolean(activeOperation),
    pythonPath: () => paddleOcrInstallPath(userDataPath, platform),
  };
}


function childEnvironment(source) {
  // Keep Python/pip children independent from Main's provider-key environment;
  // only runtime, locale, and explicitly needed package-network settings cross
  // this boundary.
  return {
    ...createOcrChildEnvironment(source, { includePackageNetwork: true }),
    PIP_DISABLE_PIP_VERSION_CHECK: "1",
    PYTHONUNBUFFERED: "1",
    PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK: "True",
  };
}

async function assertInstallDirectoryCanBeUsed(path, lstatImpl) {
  try {
    const details = await lstatImpl(path);
    // lstat keeps the userData ownership boundary intact: a symlink must not
    // redirect venv/pip writes into an arbitrary directory outside userData.
    if (details.isSymbolicLink() || !details.isDirectory()) {
      const error = new Error("PaddleOCR 安装目录已被同名文件或符号链接占用，请移除后重试。");
      error.code = "PADDLEOCR_INSTALL_PATH_INVALID";
      throw error;
    }
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
}

function assertRequirements(source, path) {
  const text = String(source || "");
  if (REQUIRED_PACKAGES.every((name) => new RegExp(`^${name}==`, "mi").test(text))) return;
  const error = new Error(`打包资源缺少 PaddleOCR 固定依赖清单：${path}`);
  error.code = "PADDLEOCR_REQUIREMENTS_MISSING";
  throw error;
}

function assertCommandResult(commandSpec, result) {
  if (result?.code === 0 || result?.code === undefined) return;
  const command = typeof commandSpec === "string" ? commandSpec : commandSpec.command;
  const detail = lastUsefulLine(result?.stderr);
  const error = new Error(detail || `PaddleOCR 安装命令失败：${command}`);
  error.code = "PADDLEOCR_INSTALL_COMMAND_FAILED";
  throw error;
}

function runProcess(command, args, { operation, cwd, env: childEnv, spawnImpl, timeoutMs }) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnImpl(command, args, {
        cwd,
        env: childEnv,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      reject(error);
      return;
    }
    operation.child = child;
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        // The close event below owns the final result.
      }
      const timeout = new Error("PaddleOCR 安装命令超时，请检查网络后重试。");
      timeout.code = "PADDLEOCR_INSTALL_TIMEOUT";
      finish(reject, timeout);
    }, timeoutMs);

    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (operation.child === child) operation.child = null;
      callback(value);
    };

    child.stdout?.on("data", (chunk) => {
      stdout = appendTail(stdout, chunk, 16 * 1024);
    });
    child.stderr?.on("data", (chunk) => {
      stderr = appendTail(stderr, chunk, 24 * 1024);
    });
    child.on("error", (error) => {
      finish(reject, error);
    });
    child.on("close", (code, signal) => {
      if (operation.cancelRequested) {
        finish(reject, canceledError());
        return;
      }
      finish(resolve, { code, signal, stdout, stderr });
    });
  });
}

function appendTail(current, chunk, limit) {
  const next = current + String(chunk);
  return next.length <= limit ? next : next.slice(-limit);
}

function lastUsefulLine(value) {
  return String(value || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1) || "";
}

function emitProgress(listener, progress) {
  if (typeof listener !== "function") return;
  try {
    listener(progress);
  } catch {
    // Progress is advisory; a detached Renderer must not fail installation.
  }
}

function throwIfCanceled(operation) {
  if (operation.cancelRequested) throw canceledError();
}

function isInstallCanceled(error, operation) {
  return operation.cancelRequested || error?.code === PADDLEOCR_INSTALL_CANCEL_CODE;
}

function canceledError() {
  const error = new Error("PaddleOCR 安装已取消，可以稍后重试；已创建的环境会被复用。");
  error.code = PADDLEOCR_INSTALL_CANCEL_CODE;
  error.canceled = true;
  return error;
}

function clearKillTimer(operation) {
  if (!operation.killTimer) return;
  clearTimeout(operation.killTimer);
  operation.killTimer = null;
}
