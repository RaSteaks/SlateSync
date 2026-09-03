// Development composition root: run Vite beside Electron so Renderer edits
// use HMR while Main/Preload continue to use the existing predev build gate.
// This script owns child-process cleanup so Ctrl-C never leaves a Vite server
// or Electron process holding the development port in the background.
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { assertMacOSPlatform } from "../lib/macos-platform-guard.mjs";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rendererUrl = process.env.SLATESYNC_RENDERER_URL || "http://localhost:5173";
const rendererTarget = new URL(rendererUrl);
const rendererPort = Number(rendererTarget.port || 80);
const legacyRequested = process.argv.includes("--slatesync-renderer=legacy");
const viteCli = resolve(projectRoot, "node_modules", "vite", "bin", "vite.js");
const viteConfig = resolve(projectRoot, "vite.renderer.config.ts");
const electronCli = resolve(projectRoot, "node_modules", "electron", "cli.js");

let viteProcess = null;
let electronProcess = null;
let shuttingDown = false;

function stopProcess(child) {
  if (child && !child.killed) child.kill();
}

function waitForPort(url, timeoutMs = 30_000) {
  const target = new URL(url);
  if (target.protocol !== "http:") throw new Error(`Renderer dev URL must use http://: ${url}`);
  const port = Number(target.port || 80);
  // macOS can resolve localhost to either loopback family depending on the
  // active network settings, so probe all local aliases before retrying.
  const hosts = [...new Set(target.hostname === "localhost"
    ? ["localhost", "127.0.0.1", "::1"]
    : [target.hostname])];
  const deadline = Date.now() + timeoutMs;

  return new Promise((resolvePromise, reject) => {
    const attempt = () => {
      if (shuttingDown) {
        reject(new Error("开发服务器等待已取消"));
        return;
      }
      const tryHost = (hostIndex) => {
        const host = hosts[hostIndex];
        if (!host) {
          if (Date.now() >= deadline) {
            reject(new Error(`Vite dev server did not start at ${url}`));
            return;
          }
          setTimeout(attempt, 100);
          return;
        }
        const socket = createConnection({ host, port });
        socket.once("connect", () => {
          socket.destroy();
          resolvePromise();
        });
        socket.once("error", () => {
          socket.destroy();
          tryHost(hostIndex + 1);
        });
      };
      tryHost(0);
    };
    attempt();
  });
}

function waitForExit(child, label) {
  return new Promise((resolvePromise, reject) => {
    child.once("error", (error) => reject(new Error(`${label} 启动失败：${error.message}`)));
    child.once("exit", (code, signal) => resolvePromise({ code: code ?? 1, signal }));
  });
}

function handleSignal(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  electronProcess?.kill(signal);
  viteProcess?.kill(signal);
}

process.on("SIGINT", () => handleSignal("SIGINT"));
process.on("SIGTERM", () => handleSignal("SIGTERM"));

async function main() {
  // Keep direct script invocation aligned with the npm lifecycle guard; this
  // prevents a caller from bypassing the macOS-only development contract.
  assertMacOSPlatform();
  const electronArgs = [electronCli, "electron/main.mjs", ...process.argv.slice(2)];
  if (legacyRequested) {
    // Explicit legacy recovery must not claim the Modern HMR port or alter
    // the selected renderer; keep this path equivalent to direct Electron.
    electronProcess = spawn(process.execPath, electronArgs, {
      cwd: projectRoot,
      env: process.env,
      stdio: "inherit",
    });
    const exit = await waitForExit(electronProcess, "Electron");
    process.exitCode = exit.code;
    return;
  }

  const childEnv = {
    ...process.env,
    SLATESYNC_RENDERER_DEV: "true",
    SLATESYNC_RENDERER_PORT: String(rendererPort),
    SLATESYNC_RENDERER_URL: rendererUrl,
  };

  // This repository intentionally keeps target-specific Vite configs instead
  // of a root vite.config.ts. Passing the Renderer config is therefore
  // required: without it Vite serves the repository root and Electron loads a
  // successful but empty development page.
  viteProcess = spawn(process.execPath, [viteCli, "--config", viteConfig], {
    cwd: projectRoot,
    env: childEnv,
    stdio: "inherit",
  });
  const viteExit = waitForExit(viteProcess, "Vite");

  try {
    await Promise.race([
      waitForPort(rendererUrl),
      viteExit.then(() => { throw new Error("Vite dev server 在启动完成前退出"); }),
    ]);
    console.log(`Renderer HMR ready at ${rendererUrl}`);

    electronProcess = spawn(process.execPath, electronArgs, {
      cwd: projectRoot,
      env: childEnv,
      stdio: "inherit",
    });

    const electronExit = waitForExit(electronProcess, "Electron");
    const result = await Promise.race([
      electronExit.then((exit) => ({ owner: "Electron", exit })),
      viteExit.then((exit) => ({ owner: "Vite", exit })),
    ]);

    if (result.owner === "Vite" && !shuttingDown) {
      console.error("Vite dev server stopped; closing Electron.");
      stopProcess(electronProcess);
      await electronExit.catch(() => undefined);
      process.exitCode = 1;
      return;
    }
    process.exitCode = shuttingDown ? 0 : result.exit.code;
  } finally {
    shuttingDown = true;
    stopProcess(electronProcess);
    stopProcess(viteProcess);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  shuttingDown = true;
  stopProcess(electronProcess);
  stopProcess(viteProcess);
  process.exitCode = 1;
});
