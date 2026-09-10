import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  createPaddleOcrInstaller,
  PADDLEOCR_INSTALL_CANCEL_CODE,
} from "../electron/paddleocr-installer.mjs";

async function withTemporaryProject(callback) {
  const root = await mkdtemp(join(tmpdir(), "slatesync-paddleocr-"));
  try {
    await writeFile(join(root, "requirements-ocr.txt"), "paddlepaddle==3.3.1\npaddleocr==3.7.0\n");
    return await callback(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("PaddleOCR installer creates a user-owned environment and verifies it", async () => {
  const previousApiKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "must-not-reach-python";
  try {
    await withTemporaryProject(async (projectDir) => {
      const commands = [];
      const progress = [];
      let checkEnvironment;
      const env = {
        ...process.env,
        SLATESYNC_PROJECT_DIR: projectDir,
        PIP_INDEX_URL: "https://packages.example.test/simple",
        HTTPS_PROXY: "http://proxy.example.test:8080",
      };
      const installer = createPaddleOcrInstaller({
        userDataPath: join(projectDir, "user-data"),
        platform: "darwin",
        env,
        runCommand: async (command, args, options) => {
          commands.push({ command, args, env: options.env });
          return { code: 0 };
        },
        checkOcr: async ({ pythonPath, env: childEnv }) => {
          checkEnvironment = childEnv;
          return {
            ok: true,
            paddleVersion: "3.3.1",
            paddleOcrVersion: "3.7.0",
            pythonPath,
          };
        },
      });

      const result = await installer.install({ onProgress: (event) => progress.push(event) });
      assert.equal(result.pythonPath, join(projectDir, "user-data", "paddleocr-venv", "bin", "python"));
      assert.equal(result.paddleVersion, "3.3.1");
      assert.equal(result.paddleOcrVersion, "3.7.0");
      assert.deepEqual(progress.map((event) => event.stage), [
        "detect-python",
        "create-environment",
        "install-dependencies",
        "verify",
        "completed",
      ]);
      assert.deepEqual(commands.map(({ args }) => args.slice(0, 4)), [
        ["--version"],
        ["-m", "venv", join(projectDir, "user-data", "paddleocr-venv")],
        ["-m", "pip", "install", "--upgrade"],
        ["-m", "pip", "install", "--disable-pip-version-check"],
      ]);
      assert.equal(commands[2]?.command, result.pythonPath);
      assert.equal(commands[3]?.command, result.pythonPath);
      // Provider credentials are Main-only state; package networking remains
      // available through the explicit proxy/index allowlist.
      assert.equal(commands[0]?.env.OPENAI_API_KEY, undefined);
      assert.equal(checkEnvironment?.OPENAI_API_KEY, undefined);
      assert.equal(commands[0]?.env.PIP_INDEX_URL, env.PIP_INDEX_URL);
      assert.equal(commands[0]?.env.HTTPS_PROXY, env.HTTPS_PROXY);
      assert.equal(installer.isInstalling(), false);
    });
  } finally {
    if (previousApiKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = previousApiKey;
  }
});

test("PaddleOCR installer rejects a symlink at the user-owned environment path", async () => {
  await withTemporaryProject(async (projectDir) => {
    const userDataPath = join(projectDir, "user-data");
    const outsidePath = join(projectDir, "outside-venv");
    await mkdir(userDataPath, { recursive: true });
    await mkdir(outsidePath, { recursive: true });
    await symlink(outsidePath, join(userDataPath, "paddleocr-venv"), "dir");
    let commandCount = 0;
    const installer = createPaddleOcrInstaller({
      userDataPath,
      platform: "darwin",
      env: { SLATESYNC_PROJECT_DIR: projectDir },
      runCommand: async () => {
        commandCount += 1;
        return { code: 0 };
      },
      checkOcr: async () => ({ ok: true }),
    });

    await assert.rejects(
      installer.install(),
      (error) => error?.code === "PADDLEOCR_INSTALL_PATH_INVALID",
    );
    // Python detection is allowed to run, but no command may create or use the
    // redirected environment after the path-boundary check rejects the link.
    assert.equal(commandCount, 1);
  });
});

test("PaddleOCR installer cancellation is observable and prevents later commands", async () => {
  await withTemporaryProject(async (projectDir) => {
    let releasePip;
    const pipGate = new Promise((resolve) => { releasePip = resolve; });
    const commands = [];
    const installer = createPaddleOcrInstaller({
      userDataPath: join(projectDir, "user-data"),
      platform: "darwin",
      env: { SLATESYNC_PROJECT_DIR: projectDir },
      runCommand: async (_command, args) => {
        commands.push(args);
        if (args.includes("--upgrade")) await pipGate;
        return { code: 0 };
      },
      checkOcr: async () => ({ ok: true, paddleVersion: "3", paddleOcrVersion: "3" }),
    });

    const installation = installer.install();
    while (!commands.some((args) => args.includes("--upgrade"))) {
      await new Promise((resolve) => setImmediate(resolve));
    }
    assert.deepEqual(installer.cancel(), { canceled: true });
    releasePip();
    await assert.rejects(installation, (error) => error?.code === PADDLEOCR_INSTALL_CANCEL_CODE);
    assert.equal(commands.some((args) => args.includes("--disable-pip-version-check")), false);
    assert.equal(installer.isInstalling(), false);
  });
});

test("PaddleOCR installer cancellation stops a verification that ignores the signal", async () => {
  await withTemporaryProject(async (projectDir) => {
    let enteredCheck;
    const checkEntered = new Promise((resolve) => { enteredCheck = resolve; });
    let releaseCheck;
    const checkGate = new Promise((resolve) => { releaseCheck = resolve; });
    const installer = createPaddleOcrInstaller({
      userDataPath: join(projectDir, "user-data"),
      platform: "darwin",
      env: { SLATESYNC_PROJECT_DIR: projectDir },
      runCommand: async () => ({ code: 0 }),
      checkOcr: async () => {
        enteredCheck();
        await checkGate;
        return { ok: true, paddleVersion: "3", paddleOcrVersion: "3" };
      },
    });

    const installation = installer.install();
    await checkEntered;
    assert.deepEqual(installer.cancel(), { canceled: true });
    await assert.rejects(
      installation,
      (error) => error?.code === PADDLEOCR_INSTALL_CANCEL_CODE,
    );
    releaseCheck();
    assert.equal(installer.isInstalling(), false);
  });
});
