import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";

// Keep generated validation output and replaceable asset copies out of Git.
// Executable baselines, fixtures, and the canonical Icon Composer source are
// deliberately outside this denylist.
const tracked = execFileSync("git", ["-c", "core.quotepath=false", "ls-files", "-z"], {
  encoding: "utf8",
}).split("\0").filter(Boolean);

const forbidden = [
  ["Icon Composer export", /^build\/[^/]* Exports\//],
  ["duplicate icon bitmap", /^(?:build\/icon\.png|assets\/slatesync-icon(?:-v\d+)?\.png)$/],
  ["raw baseline validation", /^\.codex\/refactor\/baseline\/validation\//],
  ["raw visual run", /^\.codex\/refactor\/evidence\/.*\/[^/]*visual[^/]*\//],
  ["raw visual comparison", /^\.codex\/refactor\/evidence\/.*visual-stability\.json$/],
  ["raw changed-path inventory", /^\.codex\/refactor\/evidence\/.*\/changed-paths\.json$/],
  ["raw performance result", /^\.codex\/refactor\/evidence\/.*performance.*\.json$/],
  ["raw smoke result", /^\.codex\/refactor\/evidence\/.*smoke\.json$/],
  ["raw rejected-invoke result", /^\.codex\/refactor\/evidence\/.*\/electron-rejected-invoke\.json$/],
  ["raw package listing", /^\.codex\/refactor\/evidence\/.*\/package-content\.txt$/],
];

test("repository excludes generated evidence and duplicate icon assets", () => {
  const violations = tracked.flatMap((path) => forbidden
    .filter(([, pattern]) => pattern.test(path))
    .map(([kind]) => `${kind}: ${path}`));
  assert.deepEqual(violations, []);
  assert.ok(tracked.includes("build/slatesync.icon/Assets/icon.png"));
  assert.ok(tracked.includes(".codex/refactor/baseline/visual/manifest.json"));
});
