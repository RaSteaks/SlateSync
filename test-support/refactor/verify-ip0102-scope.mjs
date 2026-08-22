#!/usr/bin/env node

// Read-only, path-exact verifier. The matrices intentionally enumerate every
// file instead of trusting directory prefixes; a newly created file therefore
// fails until an Architect assigns it to the recorded start state or package.
import { execFileSync } from "node:child_process";

const architectStart = new Set([
  ".codex/refactor/EXECUTION_GUIDE.md",
  ".codex/refactor/MASTER_PLAN.md",
  ".codex/refactor/MIGRATION_MATRIX.md",
  ".codex/refactor/packages/IP-00-C01.md",
  ".codex/refactor/packages/IP-00.md",
  ".codex/refactor/packages/IP-0102-C01.md",
  ".codex/refactor/packages/IP-0102.md",
  ".codex/refactor/packages/IP-01——IP-08.md",
  ".codex/refactor/packages/IP-03-08-CONTINUOUS.md",
  ".codex/refactor/reviews/GATE-00.md",
  ".codex/refactor/reviews/GATE-01-02.md",
]);

const gate00 = new Set([
  ".codex/refactor/baseline/BASELINE_MANIFEST.json",
  ".codex/refactor/baseline/WORKTREE.md",
  ".codex/refactor/baseline/contracts/environment.json",
  ".codex/refactor/baseline/contracts/providers.json",
  ".codex/refactor/baseline/persistence/schema.json",
  ".codex/refactor/baseline/validation/final.txt",
  ".codex/refactor/baseline/validation/preflight.txt",
  ".codex/refactor/baseline/visual/README.md",
  ".codex/refactor/baseline/visual/csv-preview.png",
  ".codex/refactor/baseline/visual/global-settings.png",
  ".codex/refactor/baseline/visual/manifest.json",
  ".codex/refactor/baseline/visual/new-project-dialog.png",
  ".codex/refactor/baseline/visual/ocr-setup-dialog.png",
  ".codex/refactor/baseline/visual/project-library.png",
  ".codex/refactor/baseline/visual/project-settings.png",
  ".codex/refactor/baseline/visual/recognition-progress.png",
  ".codex/refactor/baseline/visual/result-detail.png",
  ".codex/refactor/baseline/visual/workspace-empty.png",
  ".codex/refactor/baseline/visual/workspace-ready.png",
  ".codex/refactor/evidence/IP-00/visual/comparison.json",
  ".codex/refactor/evidence/IP-00/visual/csv-preview-run-1.png",
  ".codex/refactor/evidence/IP-00/visual/csv-preview-run-2.png",
  ".codex/refactor/evidence/IP-00/visual/human-review.md",
  ".codex/refactor/evidence/IP-00/visual/run-1-manifest.json",
  ".codex/refactor/evidence/IP-00/visual/run-2-manifest.json",
  ".codex/refactor/evidence/IP-00/visual/terminal-capture-failure.md",
  ".codex/refactor/evidence/IP-00/visual/validation.md",
  "test-support/baseline/capture-visuals.mjs",
  "test-support/baseline/verify-scope.mjs",
  "test/baseline-contracts.test.mjs",
  "test/baseline-csv.test.mjs",
  "test/baseline-persistence.test.mjs",
  "test/baseline-recognition.test.mjs",
  "test/baseline-visual.test.mjs",
  "test/fixtures/baseline/csv/manifest.json",
  "test/fixtures/baseline/csv/resolve-source-semicolon.csv",
  "test/fixtures/baseline/csv/resolve-source-utf16be.csv",
  "test/fixtures/baseline/csv/resolve-source-utf16le.csv",
  "test/fixtures/baseline/csv/resolve-source-utf8.csv",
  "test/fixtures/baseline/csv/resolve-source.csv",
  "test/fixtures/baseline/persistence/legacy-migration.json",
  "test/fixtures/baseline/persistence/library.json",
  "test/fixtures/baseline/persistence/project.json",
  "test/fixtures/baseline/persistence/settings.json",
  "test/fixtures/baseline/persistence/task.json",
  "test/fixtures/baseline/recognition/normalization.json",
  "test/fixtures/baseline/recognition/pages.json",
  "test/fixtures/baseline/recognition/timeout.json",
]);

const ip01 = new Set([
  ".github/workflows/ci.yml",
  ".github/workflows/release.yml",
  ".codex/refactor/baseline/contracts/build.json",
  ".codex/refactor/baseline/contracts/electron.json",
  ".codex/refactor/evidence/IP-01/COMPLETION.md",
  ".codex/refactor/evidence/IP-01/changed-paths.json",
  ".codex/refactor/evidence/IP-01/package-content.txt",
  ".codex/refactor/evidence/IP-01/packaged-smoke.json",
  ".codex/refactor/evidence/IP-01/performance.json",
  ".codex/refactor/evidence/IP-01/production-smoke.json",
  "electron-builder.yml",
  "electron/main.mjs",
  "package-lock.json",
  "package.json",
  "src/main/index.ts",
  "src/main/renderer-entry.ts",
  "src/renderer/index.html",
  "src/renderer/main.tsx",
  "src/renderer/styles.css",
  "test-support/refactor/electron-smoke.mjs",
  "test-support/refactor/verify-ip0102-scope.mjs",
  "test/refactor/ip-01/skeleton.test.ts",
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

const ip02 = new Set([
  ".codex/refactor/COMPATIBILITY_CONTRACT.md",
  ".codex/refactor/DECISION_QUEUE.md",
  ".codex/refactor/adr/ADR-IP-0102-TYPED-GATEWAY.md",
  ".codex/refactor/baseline/contracts/ipc.json",
  ".codex/refactor/evidence/IP-0102/COMPLETION_REPORT.md",
  ".codex/refactor/evidence/IP-0102/START_INVENTORY.md",
  ".codex/refactor/evidence/IP-0102/changed-paths.json",
  ".codex/refactor/evidence/IP-02/COMPLETION.md",
  ".codex/refactor/evidence/IP-02/changed-paths.json",
  ".codex/refactor/evidence/IP-02/electron-rejected-invoke.json",
  ".codex/refactor/evidence/IP-02/performance.json",
  "electron/preload.cjs",
  "public/electron-bridge.js",
  "src/preload/index.ts",
  "src/shared/contracts/index.ts",
  "src/shared/domain/index.ts",
  "src/shared/errors/index.ts",
  "src/shared/index.ts",
  "test-support/refactor/gateway-performance.mjs",
  "test-support/refactor/legacy-test-gateway.mjs",
  "test/electron-bridge.test.mjs",
  "test/refactor/ip-02/contract.test.ts",
  "test/refactor/ip-02/destroyed-sender.test.mjs",
]);

const packageMatrices = {
  "ip-01": ip01,
  "ip-02": ip02,
  "ip-0102": new Set([...ip01, ...ip02]),
};

function lines(command, args) {
  return execFileSync(command, args, { encoding: "utf8" })
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

const requested = process.argv.find((argument) => argument.startsWith("--scope="))?.slice("--scope=".length) || "ip-0102";
const packageMatrix = packageMatrices[requested];
if (!packageMatrix) {
  console.error("Usage: verify-ip0102-scope.mjs --scope=ip-01|ip-02|ip-0102");
  process.exit(2);
}

const changed = new Set([
  ...lines("git", ["-c", "core.quotepath=false", "diff", "--name-only", "HEAD"]),
  ...lines("git", ["-c", "core.quotepath=false", "diff", "--cached", "--name-only"]),
  ...lines("git", ["-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard"]),
]);
const fullInventory = new Set([...architectStart, ...gate00, ...ip01, ...ip02]);
const outside = [...changed].filter((path) => !fullInventory.has(path));
const generatedOutsideOut = [...changed].filter((path) =>
  /^tsconfig\..*\.tsbuildinfo$/.test(path)
  || /^src\/shared\/.*\.(?:js|js\.map|d\.ts|d\.ts\.map)$/.test(path),
);
const protectedChanges = [...changed].filter((path) =>
  /^lib\//.test(path)
  || /^electron\/(?!main\.mjs$|preload\.cjs$)/.test(path)
  || /^public\/(?!electron-bridge\.js$)/.test(path),
);
const packagePaths = [...changed].filter((path) => packageMatrix.has(path)).sort();

const required = requested === "ip-01"
  ? ["electron/main.mjs", "src/main/renderer-entry.ts", "test-support/refactor/electron-smoke.mjs"]
  : requested === "ip-02"
    ? ["electron/preload.cjs", "src/shared/contracts/index.ts", "test/electron-bridge.test.mjs"]
    : ["electron/main.mjs", "electron/preload.cjs", "src/shared/contracts/index.ts"];
const missingRequired = required.filter((path) => !changed.has(path));

if (outside.length || generatedOutsideOut.length || protectedChanges.length || missingRequired.length) {
  console.error(`${requested} scope violation:`);
  for (const path of outside) console.error(`- no exact attribution: ${path}`);
  for (const path of generatedOutsideOut) console.error(`- generated artifact outside out/**: ${path}`);
  for (const path of protectedChanges) console.error(`- Protected Scope changed: ${path}`);
  for (const path of missingRequired) console.error(`- required package path absent: ${path}`);
  process.exitCode = 1;
} else {
  console.log(`${requested} scope OK (${packagePaths.length} exact package paths; ${changed.size} cumulative paths; Protected Scope intact)`);
  for (const path of packagePaths) console.log(path);
}
