import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createOcrEnvironmentProbe } from "../electron/ocr-environment.mjs";

// Fake spawn returns an EventEmitter child whose stdout/stderr/close/error
// events replay a scripted result on the next tick, mirroring how the real
// probe consumes version banners and sw_vers output.
function createFakeSpawn(respond) {
  const calls = [];
  function fakeSpawn(command, args, options) {
    calls.push({ command, args, options });
    const result = respond(command, args) || { error: `spawn ${command} ENOENT` };
    const child = new EventEmitterFake();
    queueMicrotask(() => {
      if (result.error) {
        child.emit("error", new Error(result.error));
        return;
      }
      if (result.stdout) child.stdout.emit("data", Buffer.from(result.stdout));
      if (result.stderr) child.stderr.emit("data", Buffer.from(result.stderr));
      child.emit("close", result.code ?? 0);
    });
    return child;
  }
  fakeSpawn.calls = calls;
  return fakeSpawn;
}

class EventEmitterFake {
  constructor() {
    this.listeners = new Map();
    this.stdout = this.emitter("stdout");
    this.stderr = this.emitter("stderr");
    this.killed = false;
  }
  emitter() {
    const listeners = new Map();
    return {
      on(event, listener) {
        listeners.set(event, [...(listeners.get(event) || []), listener]);
      },
      emit(event, payload) {
        for (const listener of listeners.get(event) || []) listener(payload);
      },
    };
  }
  on(event, listener) {
    this.listeners.set(event, [...(this.listeners.get(event) || []), listener]);
  }
  emit(event, payload) {
    for (const listener of this.listeners.get(event) || []) listener(payload);
  }
  kill() {
    this.killed = true;
  }
}

function pythonResponder({ python3, python, py, swVers }) {
  return (command, args) => {
    if (command === "sw_vers") return swVers;
    if (command === "py" && args[0] === "-3") return py;
    if (command === "python3") return python3;
    if (command === "python") return python;
    return null;
  };
}

async function createUserData({ withVenv = false } = {}) {
  const userDataPath = await mkdtemp(join(tmpdir(), "slatesync-ocr-env-"));
  if (withVenv) {
    await mkdir(join(userDataPath, "paddleocr-venv", "bin"), { recursive: true });
    await writeFile(join(userDataPath, "paddleocr-venv", "bin", "python"), "#!/bin/sh\n");
  }
  return userDataPath;
}

describe("OCR environment probe", () => {
  it("snapshots a healthy macOS arm64 development machine", async () => {
    const userDataPath = await createUserData({ withVenv: true });
    try {
      const spawnImpl = createFakeSpawn(pythonResponder({
        python3: { stdout: "Python 3.12.4\n" },
        swVers: { stdout: "15.5\n" },
      }));
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "/usr/bin:/bin", HOME: "/Users/tester" },
        platform: "darwin",
        arch: "arm64",
        spawnImpl,
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.platform, "darwin");
      assert.equal(snapshot.platformLabel, "macOS 15.5");
      assert.equal(snapshot.architecture, "arm64");
      assert.equal(snapshot.architectureLabel, "Apple Silicon（arm64）");
      assert.equal(snapshot.packaged, false);
      assert.deepEqual(snapshot.python, {
        found: true,
        command: "python3",
        version: "Python 3.12.4",
        meetsMinimum: true,
        candidates: ["python3"],
        error: null,
      });
      assert.equal(snapshot.paddle.venvPath, join(userDataPath, "paddleocr-venv"));
      assert.equal(snapshot.paddle.pythonPath, join(userDataPath, "paddleocr-venv", "bin", "python"));
      assert.equal(snapshot.paddle.venvExists, true);
      // Only python3 answered, so the probe never reached the second alias.
      assert.deepEqual(spawnImpl.calls.map((call) => call.command), ["sw_vers", "python3"]);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("reports the installer guidance when no Python alias responds", async () => {
    const userDataPath = await createUserData();
    try {
      const spawnImpl = createFakeSpawn(pythonResponder({}));
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "/usr/bin:/bin" },
        platform: "darwin",
        arch: "arm64",
        spawnImpl,
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.python.found, false);
      assert.equal(snapshot.python.meetsMinimum, null);
      assert.deepEqual(snapshot.python.candidates, ["python3", "python"]);
      assert.match(snapshot.python.error, /Python 3\.10 或更高版本/);
      assert.equal(snapshot.paddle.venvExists, false);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("flags interpreters below the installer minimum", async () => {
    const userDataPath = await createUserData();
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "/usr/bin:/bin" },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.9.7\n" },
          swVers: { stdout: "14.6.1\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "23.6.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.python.found, true);
      assert.equal(snapshot.python.version, "Python 3.9.7");
      assert.equal(snapshot.python.meetsMinimum, false);
      assert.equal(snapshot.python.error, null);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("falls back to the Darwin release when sw_vers is unavailable", async () => {
    const userDataPath = await createUserData();
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "/usr/bin:/bin" },
        platform: "darwin",
        arch: "x64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { error: "spawn sw_vers ENOENT" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.platformLabel, "macOS 24.5.0");
      assert.equal(snapshot.architectureLabel, "Intel（x64）");
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("probes the Windows py launcher before the bare aliases", async () => {
    const userDataPath = await createUserData();
    try {
      const spawnImpl = createFakeSpawn(pythonResponder({
        python: { stderr: "Python 3.11.9\n" },
      }));
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "C:\\Windows\\System32" },
        platform: "win32",
        arch: "x64",
        spawnImpl,
        existsImpl: existsSync,
        osRelease: () => "10.0.22631",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.platformLabel, "Windows");
      // The launcher is probed first and only stderr carried the banner.
      assert.deepEqual(spawnImpl.calls[0].args, ["-3", "--version"]);
      assert.deepEqual(spawnImpl.calls.map((call) => call.command), ["py", "python"]);
      assert.equal(snapshot.python.command, "python");
      assert.equal(snapshot.python.version, "Python 3.11.9");
      assert.equal(snapshot.python.meetsMinimum, true);
      assert.equal(snapshot.paddle.pythonPath, join(userDataPath, "paddleocr-venv", "Scripts", "python.exe"));
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("keeps provider credentials out of probe child environments", async () => {
    const userDataPath = await createUserData();
    try {
      const spawnImpl = createFakeSpawn(pythonResponder({
        python3: { stdout: "Python 3.12.4\n" },
        swVers: { stdout: "15.5\n" },
      }));
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          OPENAI_API_KEY: "sk-test-do-not-leak",
          HTTPS_PROXY: "http://proxy.internal:7890",
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl,
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      await probe.snapshot();

      assert.ok(spawnImpl.calls.length >= 2);
      for (const call of spawnImpl.calls) {
        assert.equal(call.options.env.OPENAI_API_KEY, undefined);
        assert.equal(call.options.env.PATH, "/usr/bin:/bin");
      }
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("classifies the Vision bridge source for packaged, local-build, and explicit setups", async () => {
    const userDataPath = await createUserData();
    const explicitBinary = join(userDataPath, "vision-ocr");
    await writeFile(explicitBinary, "#!/bin/sh\n");
    // Synthetic project dirs keep the bundled-path classification hermetic:
    // the real repository may or may not carry a compiled bin/vision-ocr.
    const packagedProjectDir = join(userDataPath, "packaged-project");
    const devProjectDir = join(userDataPath, "dev-project");
    const builtBinary = join(devProjectDir, "bin", "vision-ocr");
    await mkdir(join(devProjectDir, "bin"), { recursive: true });
    await writeFile(builtBinary, "#!/bin/sh\n");
    try {
      const packagedProbe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          SLATESYNC_PACKAGED: "true",
          SLATESYNC_PROJECT_DIR: packagedProjectDir,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });
      const packaged = await packagedProbe.snapshot();
      assert.equal(packaged.packaged, true);
      assert.equal(packaged.vision.source, "missing");
      assert.equal(packaged.vision.binaryExists, false);
      // Packaged runtimes must not promise an on-demand build.
      assert.equal(packaged.vision.swiftToolchain, false);

      const localBuildProbe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          SLATESYNC_PROJECT_DIR: devProjectDir,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });
      const localBuild = await localBuildProbe.snapshot();
      assert.equal(localBuild.packaged, false);
      assert.equal(localBuild.vision.source, "local-build");
      assert.equal(localBuild.vision.binaryExists, true);
      assert.equal(localBuild.vision.binaryPath, builtBinary);

      const explicitProbe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          VISIONOCR_BINARY: explicitBinary,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });
      const explicit = await explicitProbe.snapshot();
      assert.equal(explicit.vision.source, "explicit");
      assert.equal(explicit.vision.binaryExists, true);
      assert.equal(explicit.vision.binaryPath, explicitBinary);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("reports an unparseable banner instead of claiming Python is missing", async () => {
    const userDataPath = await createUserData();
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: { PATH: "/usr/bin:/bin" },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Interpreter ready\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.python.found, false);
      assert.equal(snapshot.python.meetsMinimum, null);
      assert.match(snapshot.python.error, /无法解析版本输出/);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("reports the pinned PaddleOCR Python path as the effective interpreter", async () => {
    const userDataPath = await createUserData();
    const pinnedPython = join(userDataPath, "custom-venv", "bin", "python");
    await mkdir(join(userDataPath, "custom-venv", "bin"), { recursive: true });
    await writeFile(pinnedPython, "#!/bin/sh\n");
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          PADDLEOCR_PYTHON: pinnedPython,
          SLATESYNC_PROJECT_DIR: userDataPath,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      // The effective interpreter mirrors recognition, not the installer venv.
      assert.equal(snapshot.paddle.configuredPythonPath, pinnedPython);
      assert.equal(snapshot.paddle.activePythonPath, pinnedPython);
      assert.equal(snapshot.paddle.activePythonExists, true);
      assert.equal(snapshot.paddle.venvExists, false);
      assert.equal(snapshot.paddle.pythonPath, join(userDataPath, "paddleocr-venv", "bin", "python"));
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("falls back to the workspace venv before auto-discovery", async () => {
    const userDataPath = await createUserData();
    const projectDir = join(userDataPath, "project");
    const workspacePython = join(projectDir, ".venv-paddleocr", "bin", "python");
    await mkdir(join(projectDir, ".venv-paddleocr", "bin"), { recursive: true });
    await writeFile(workspacePython, "#!/bin/sh\n");
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          SLATESYNC_PROJECT_DIR: projectDir,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.paddle.configuredPythonPath, "");
      assert.equal(snapshot.paddle.activePythonPath, workspacePython);
      assert.equal(snapshot.paddle.activePythonExists, true);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("reports auto-discovery when neither a pinned path nor a workspace venv exists", async () => {
    const userDataPath = await createUserData();
    try {
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: {
          PATH: "/usr/bin:/bin",
          SLATESYNC_PROJECT_DIR: userDataPath,
        },
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const snapshot = await probe.snapshot();

      assert.equal(snapshot.paddle.configuredPythonPath, "");
      assert.equal(snapshot.paddle.activePythonPath, "");
      assert.equal(snapshot.paddle.activePythonExists, null);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("resolves the environment lazily on every snapshot", async () => {
    const userDataPath = await createUserData();
    const pinnedPython = join(userDataPath, "late-venv", "bin", "python");
    await mkdir(join(userDataPath, "late-venv", "bin"), { recursive: true });
    await writeFile(pinnedPython, "#!/bin/sh\n");
    try {
      const runtimeGlobalConfig = {};
      const probe = createOcrEnvironmentProbe({
        userDataPath,
        env: () => ({
          PATH: "/usr/bin:/bin",
          PADDLEOCR_PYTHON: runtimeGlobalConfig.PADDLEOCR_PYTHON || "",
          SLATESYNC_PROJECT_DIR: userDataPath,
        }),
        platform: "darwin",
        arch: "arm64",
        spawnImpl: createFakeSpawn(pythonResponder({
          python3: { stdout: "Python 3.12.4\n" },
          swVers: { stdout: "15.5\n" },
        })),
        existsImpl: existsSync,
        osRelease: () => "24.5.0",
      });

      const before = await probe.snapshot();
      assert.equal(before.paddle.activePythonPath, "");

      // Saving the path in Global Settings must be visible to the next probe
      // without recreating the Main-side probe instance.
      runtimeGlobalConfig.PADDLEOCR_PYTHON = pinnedPython;
      const after = await probe.snapshot();
      assert.equal(after.paddle.configuredPythonPath, pinnedPython);
      assert.equal(after.paddle.activePythonPath, pinnedPython);
      assert.equal(after.paddle.activePythonExists, true);
    } finally {
      await rm(userDataPath, { recursive: true, force: true });
    }
  });

  it("requires the Electron userData path", () => {
    assert.throws(() => createOcrEnvironmentProbe({}), /userData/);
  });
});
