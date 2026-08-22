#!/usr/bin/env node

// A native addon in the shared node_modules tree can target only one runtime
// ABI at a time. This controller owns the Electron switch and always restores
// the system Node binding, including when the Electron probe fails.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const electronBinary = require("electron");
const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
const timeoutMs = 180_000;
const probeMarker = "SLATESYNC_NATIVE_ABI_PROBE ";
const probeSource = `
const Database = require("better-sqlite3");
const database = new Database(":memory:");
database.exec("CREATE TABLE probe (value TEXT NOT NULL)");
database.prepare("INSERT INTO probe (value) VALUES (?)").run("ok");
const row = database.prepare("SELECT value FROM probe").get();
const sqliteVersion = database.prepare("SELECT sqlite_version() AS version").get().version;
database.close();
process.stdout.write(${JSON.stringify(probeMarker)} + JSON.stringify({
  runtime: process.versions.electron ? "electron" : "node",
  modules: process.versions.modules,
  electron: process.versions.electron || null,
  sqliteVersion,
  row,
}) + "\\n");
`;

function run(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    const collect = (chunk) => {
      output = `${output}${chunk}`.slice(-200_000);
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`${command} timed out after ${timeoutMs}ms\n${output}`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    // electron-rebuild can leave a grandchild holding an inherited output
    // pipe after the npm process itself has exited. The direct child's exit
    // status is the command contract; waiting for every inherited fd to close
    // can otherwise turn a successful rebuild into a false timeout.
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`${command} failed (${signal || code})\n${output}`));
        return;
      }
      resolvePromise(output);
    });
  });
}

async function rebuild(target) {
  return run(npmCommand, ["run", `rebuild:native:${target}`]);
}

function parseProbe(output, expectedRuntime) {
  const line = output.split("\n").find((candidate) => candidate.startsWith(probeMarker));
  assert(line, `missing ${expectedRuntime} native ABI probe marker:\n${output}`);
  const facts = JSON.parse(line.slice(probeMarker.length));
  assert.equal(facts.runtime, expectedRuntime);
  assert.equal(facts.row?.value, "ok");
  assert.match(facts.modules, /^\d+$/);
  assert.match(facts.sqliteVersion, /^\d+\.\d+\.\d+$/);
  return facts;
}

let electronFacts;
let nodeFacts;
let primaryError = null;

try {
  await rebuild("electron");
  const electronOutput = await run(electronBinary, ["--eval", probeSource], {
    env: { ELECTRON_RUN_AS_NODE: "1" },
  });
  electronFacts = parseProbe(electronOutput, "electron");
} catch (error) {
  primaryError = error;
} finally {
  // Restoration is part of the test contract, not best-effort cleanup. The
  // final Node probe proves the worktree is usable by the next test command.
  await rebuild("node");
  const nodeOutput = await run(process.execPath, ["--eval", probeSource]);
  nodeFacts = parseProbe(nodeOutput, "node");
}

if (primaryError) throw primaryError;
process.stdout.write(`${JSON.stringify({ electron: electronFacts, node: nodeFacts }, null, 2)}\n`);
process.stdout.write("SLATESYNC_NATIVE_ABI_LIFECYCLE_OK\n");
