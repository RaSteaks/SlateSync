# Standalone `.gitignore` hygiene authorization

Decision: `IP-03-08-REPO-HYGIENE-001`  
Authorized: Owner direction, 2026-08-22 (Asia/Shanghai)  
Status: **OWNER AUTHORIZED — STANDALONE**

## Objective

Keep reproducible build output, test-run output, local environment variants,
and redundant visual captures out of future commits without changing runtime
code, test behavior, compatibility contracts, or required acceptance evidence.

## Allowed Scope

Only the repository-root `.gitignore` may change under this authorization. The
current rules cover:

- local `.env.*` variants while retaining `.env.example`;
- Storybook, Playwright, Vite, and TypeScript generated output;
- redundant IP-03-08 visual captures from contained runs 1–24, `visual-run-1`,
  and the superseded C02 visual runs.

The required baseline images, IP-00 historical captures, final stable runs
25–26, and final-handoff visual reruns remain visible to Git.

## Protected Scope

Production code, tests, fixtures, dependencies, lockfiles, workflows, package
contents, migration evidence, required baseline/final evidence, the quarantined
Project Library, and Git history are outside this hygiene authorization. No
file is deleted, rewritten, staged, committed, pushed, reset, or cleaned.

## Acceptance Evidence

- `node .codex/refactor/verify-current-state.mjs` passes.
- `node test-support/refactor/verify-ip0308-scope.mjs` reports a separate
  `hygiene=1` attribution for `.gitignore` and no out-of-scope path.
- `git diff --check` passes.
- Redundant visual captures remain on disk but are ignored; 52 required PNGs
  remain visible to Git.
- No production or test source file changes are introduced by this record.

## Stop Conditions

Stop and request a new authorization if any path other than `.gitignore` is
added to the hygiene bucket, if a required evidence path becomes ignored, or
if any cleanup would require accessing user data or mutating Git history.

