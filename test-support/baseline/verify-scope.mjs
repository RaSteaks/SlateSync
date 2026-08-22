#!/usr/bin/env node

// Scope verification is deliberately read-only: it reports every tracked and
// untracked path instead of trying to clean the worktree into compliance.
import { execFileSync } from "node:child_process";

const allowedExactFiles = new Set([
  ".codex/refactor/COMPATIBILITY_CONTRACT.md",
  ".codex/refactor/MIGRATION_MATRIX.md",
  ".codex/refactor/DECISION_QUEUE.md",
]);
const allowedDirectories = [
  ".codex/refactor/baseline/",
  "test/fixtures/baseline/",
  "test-support/baseline/",
];
const allowedTestPattern = /^test\/baseline-[^/]+\.test\.mjs$/;
// Architect-authored packages/reviews are pre-existing control documents, not
// Implementer scope. List them exactly so similarly prefixed files stay denied.
const knownArchitectArtifacts = new Set([
  ".codex/refactor/packages/IP-00.md",
  ".codex/refactor/packages/IP-00-C01.md",
  ".codex/refactor/packages/IP-01——IP-08.md",
  ".codex/refactor/reviews/GATE-00.md",
]);

function lines(command, args) {
  return execFileSync(command, args, { encoding: "utf8" })
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

const tracked = [
  ...lines("git", ["-c", "core.quotepath=false", "diff", "--name-only", "HEAD"]),
  ...lines("git", ["-c", "core.quotepath=false", "diff", "--cached", "--name-only"]),
];
// Disable Git's C-style quoting so exact Unicode Architect filenames compare
// against repository paths rather than their escaped display representation.
const untracked = lines("git", [
  "-c",
  "core.quotepath=false",
  "ls-files",
  "--others",
  "--exclude-standard",
]);
const paths = [...new Set([...tracked, ...untracked])];
const outside = paths.filter((path) =>
  !knownArchitectArtifacts.has(path) &&
  !allowedExactFiles.has(path) &&
  !allowedDirectories.some((directory) => path.startsWith(directory)) &&
  !allowedTestPattern.test(path),
);

if (outside.length) {
  console.error("IP-00 scope violation:");
  for (const path of outside) console.error(`- ${path}`);
  process.exitCode = 1;
} else {
  console.log(`IP-00 scope OK (${paths.length} changed/created paths)`);
}
