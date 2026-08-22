import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repo = process.cwd();

function git(args) {
  return execFileSync("git", args, { cwd: repo, encoding: "utf8" }).trim();
}

function gitPaths(args) {
  return execFileSync("git", [...args, "-z"], { cwd: repo, encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
}

function fail(message) {
  console.error(`IP0308_SCOPE_FAIL: ${message}`);
  process.exitCode = 1;
}

const manifestPath = join(repo, ".codex/refactor/CONTINUOUS_CLEANUP_MANIFEST.md");
const manifest = readFileSync(manifestPath, "utf8");

// Gate-01/02 deliberately left a dirty foundation. These are the tracked
// baseline paths plus the path families enumerated by its path-exact verifier;
// keeping this attribution separate prevents a correction from silently
// redefining the approved foundation.
const gateTrackedPaths = new Set([
  ".codex/refactor/ARCHITECTURE_INVARIANTS.md",
  ".codex/refactor/EXECUTION_GUIDE.md",
  ".codex/refactor/MASTER_PLAN.md",
  ".codex/refactor/packages/IP-01—IP-08.md",
  ".github/workflows/ci.yml",
  ".github/workflows/release.yml",
  "README.md",
  "electron-builder.yml",
  "electron/main.mjs",
  "electron/preload.cjs",
  "package-lock.json",
  "package.json",
  "public/csv-worker.js",
  "public/electron-bridge.js",
  "test/electron-bridge.test.mjs",
]);

const gateExactPaths = new Set([
  ".codex/refactor/packages/IP-00-C01.md",
  ".codex/refactor/packages/IP-00.md",
  ".codex/refactor/packages/IP-0102-C01.md",
  ".codex/refactor/packages/IP-0102.md",
  ".codex/refactor/packages/IP-01——IP-08.md",
  ".codex/refactor/reviews/GATE-00.md",
  ".codex/refactor/reviews/GATE-01-02.md",
  "playwright.config.ts",
  "test-support/refactor/electron-smoke.mjs",
  "test-support/refactor/gateway-performance.mjs",
  "test-support/refactor/legacy-test-gateway.mjs",
  "test-support/refactor/verify-ip0102-scope.mjs",
  "test/refactor/ip-01/skeleton.test.ts",
  "test/refactor/ip-02/contract.test.ts",
  "test/refactor/ip-02/destroyed-sender.test.mjs",
  "src/main/index.ts",
  "src/main/renderer-entry.ts",
  "src/preload/index.ts",
  "src/shared/contracts/index.ts",
  "src/shared/domain/index.ts",
  "src/shared/errors/index.ts",
  "src/shared/index.ts",
  "tsconfig.base.json",
  "tsconfig.json",
  "tsconfig.main.json",
  "tsconfig.preload.json",
  "tsconfig.renderer.json",
  "tsconfig.shared.json",
  "vite.preload.config.ts",
  "vite.renderer.config.ts",
  "vitest.config.ts",
]);

function inGateBaseline(path) {
  return gateTrackedPaths.has(path)
    || gateExactPaths.has(path)
    || path.startsWith(".codex/refactor/baseline/")
    || /^\.codex\/refactor\/evidence\/(?:IP-00|IP-01|IP-02|IP-0102)\//.test(path)
    || path.startsWith("test-support/baseline/")
    || /^test\/baseline-(?:contracts|csv|persistence|recognition|visual)\.test\.mjs$/.test(path)
    || path.startsWith("test/fixtures/baseline/");
}

const continuousExactPaths = new Set([
  ".codex/refactor/COMPATIBILITY_CONTRACT.md",
  ".codex/refactor/CONTINUOUS_CLEANUP_MANIFEST.md",
  ".codex/refactor/CURRENT_STATE.json",
  ".codex/refactor/DECISION_QUEUE.md",
  ".codex/refactor/IP-03-08-TRACEABILITY.md",
  ".codex/refactor/MIGRATION_MATRIX.md",
  ".codex/refactor/README.md",
  ".codex/refactor/REPOSITORY_HYGIENE.md",
  ".codex/refactor/packages/IP-03-08-CONTINUOUS.md",
  ".codex/refactor/verify-current-state.mjs",
  "AGENT.md",
  "AGENTS.md",
  "public/csv-background-tasks.js",
  "public/csv-worker.js",
  "public/csv-worker-client.js",
  "public/image-preprocess.js",
  "public/recognition-request.js",
  "public/resolve-csv.js",
  "public/task-persistence.js",
  "test/csv-background-tasks.test.mjs",
  "test-support/refactor/native-abi-lifecycle.mjs",
  "test-support/refactor/verify-ip0308-scope.mjs",
]);

// The Owner authorized the root ignore-file update as a standalone repository
// hygiene change. Keeping it in its own attribution bucket prevents a
// housekeeping rule from widening the production or evidence scope.
const hygieneExactPaths = new Set([".gitignore"]);

function inContinuousPackage(path) {
  return continuousExactPaths.has(path)
    || path.startsWith(".codex/refactor/adr/")
    || path.startsWith(".codex/refactor/evidence/IP-03-08/")
    || path.startsWith(".storybook/")
    || path.startsWith("src/renderer/")
    || path.startsWith("test/e2e/")
    || path.startsWith("test/refactor/ip-03-08/")
    || path.startsWith("test-support/e2e/")
    || path.startsWith("test/fixtures/refactor/")
    || path.startsWith("storybook-static/")
    || path.startsWith("test-results/");
}

const correctionExactPaths = new Set([
  ".codex/refactor/packages/IP-03-08-C01.md",
  ".codex/refactor/packages/IP-03-08-C02.md",
  ".codex/refactor/packages/IP-03-08-C03.md",
  ".codex/refactor/reviews/FINAL-IP-03-08.md",
  "src/renderer/features/projects/ProjectLibraryPage.tsx",
  "src/renderer/features/recognition/RecognitionResultPanel.tsx",
  "src/renderer/features/slate/SlateInputPanel.tsx",
  "src/renderer/features/tasks/TaskRail.tsx",
  "src/renderer/features/workspace/WorkspacePage.tsx",
  "src/renderer/services/csv-worker-service.ts",
  "src/renderer/services/preparation-service.ts",
  "src/renderer/services/task-autosave.ts",
  "src/renderer/state/export-store.ts",
  "src/renderer/state/metadata-store.ts",
  "src/renderer/state/recognition-store.ts",
  "src/renderer/state/slate-store.ts",
  "src/renderer/state/task-store.ts",
  "src/renderer/state/types.ts",
  "src/renderer/workers/preparation.worker.ts",
]);

function attribution(path) {
  if (hygieneExactPaths.has(path)) return "hygiene";
  if (inGateBaseline(path)) return "gate";
  if (correctionExactPaths.has(path)) return "c02";
  if (inContinuousPackage(path)) return "continuous";
  return null;
}

const changed = new Set([
  ...gitPaths(["diff", "--name-only"]),
  ...gitPaths(["ls-files", "--others", "--exclude-standard"]),
]);
const counts = { gate: 0, continuous: 0, c02: 0, hygiene: 0 };
for (const path of changed) {
  const owner = attribution(path);
  if (!owner) fail(`out-of-scope path: ${path}`);
  else counts[owner] += 1;
}

// A deletion is safe only when the exact path is present in the manifest.
// This run intentionally has no deletion, but keeping the check executable
// prevents a future cleanup from silently widening its authorization.
const deleted = gitPaths(["diff", "--name-only", "--diff-filter=D"]);
for (const path of deleted) {
  const exactRow = new RegExp(`\\| ${path.replace(/[.*+?^{}()|[\\]\\]/g, "\\$&")} \\|`).test(manifest);
  if (!exactRow) fail(`deleted path is absent from exact manifest: ${path}`);
}

const packageJson = JSON.parse(readFileSync(join(repo, "package.json"), "utf8"));
const lockJson = JSON.parse(readFileSync(join(repo, "package-lock.json"), "utf8"));
const lockRoot = lockJson.packages?.[""];
if (!lockRoot) {
  fail("package-lock.json has no root package entry");
} else {
  for (const section of ["dependencies", "devDependencies"]) {
    const declared = packageJson[section] ?? {};
    const locked = lockRoot[section] ?? {};
    if (JSON.stringify(declared) !== JSON.stringify(locked)) {
      fail(`lockfile root ${section} does not match package.json`);
    }
    for (const name of Object.keys(declared)) {
      if (!lockJson.packages[`node_modules/${name}`]) {
        fail(`direct dependency is missing from lockfile packages: ${name}`);
      }
    }
  }
}

if (process.exitCode) process.exit();
console.log(`IP0308_SCOPE_OK changed=${changed.size} gate=${counts.gate} continuous=${counts.continuous} c02=${counts.c02} hygiene=${counts.hygiene} deleted=${deleted.length} manifestDeletions=0 lockfile=exact-root-match`);
