# IP-03—IP-08 Continuous Checkpoint Ledger

Recorded: 2026-08-21 (Asia/Shanghai)

> Repository cleanup note (2026-09-05): raw screenshots and generated JSON
> outputs named below were removed after approval. The executed-result summary
> remains historical evidence; executable tests and visual baselines remain.

## Admission and baseline

- Authority: .codex/refactor/packages/IP-03-08-CONTINUOUS.md
- Authority version/SHA: 2026-08-21.2 /
  67a4d98e90950a78a04e4ab2b5a6b6a164408567dee83f6d211b2b4e54a2c164
- Admission: Gate-01/02 APPROVED; initial current-state verifier passed.
- HEAD at start and handoff: c7dafa4d972e5eb7be61f00e2b546d6826e70c87.
- Branch: codex/react-architecture-refactor.
- Staged paths: none; no commit, reset, clean, branch switch, or push.
- Gate-approved dirty worktree: preserved. Start inventory is in
  START_INVENTORY.md.
- User-data safety: the accidentally reached default macOS Library was
  audited only at path/metadata level, quarantined, and never opened,
  parsed, hashed, copied, migrated, archived, deleted, or rewritten.
  All subsequent Electron work used an explicit temporary libraryPath.

## Workstream checkpoints

### Workstream 1 — Design System and Static AppShell

- Commands and results: npm run typecheck (0); npm run test:component
  (0, 7 files/15 tests); npm run build:storybook (0); final npm run check
  (0); final npm run build:modern (0).
- Approximate durations: typecheck 0.25 s; component runner 0.70 s;
  Storybook build about 7 s; modern build about 0.6 s.
- Implementation: semantic tokens, domain-neutral primitives, feature
  composition, Dialog focus lifecycle, route focus/scroll reset, field
  error ownership, and reduced-motion styles.
- Comments: updated focus restoration/portal lifecycle, route scroll
  ownership, field ARIA ownership, and test/evidence lifecycle comments.
- Compatibility/performance: no Shared Contract, IPC, persistence, or CSV
  change; final gzip renderer 104.89 kB and CSS 6.26 kB.
- Evidence: VISUAL-ACCESSIBILITY-REVIEW.md and visual-contained-run-25/26.

### Workstream 2 — Project Library and Settings

- Commands and results: isolated Electron E2E fresh runs and copied
  version-1 Library run passed; baseline persistence/migration tests passed
  as part of npm run test:node and npm test; production smoke passed.
- Approximate durations: fresh/version-1 E2E cases 0.57–1.0 s each;
  aggregate E2E 4.7 s; Node aggregate 1.16 s after native preparation.
- Implementation: explicit project/workspace/settings route state and
  project/ui ownership were integrated through existing contracts; no
  production Library path was used by the tests.
- Comments: settings lifecycle and validation ownership comments retained;
  isolation launcher explains macOS appData/libraryPath behavior.
- Evidence: LIBRARY-IMPACT-AUDIT.md, E2E-ISOLATION-INCIDENT.md, and
  test/e2e/electron.spec.ts.

### Workstream 3 — Slate Input and Preparation

- Commands and results: complete Node/baseline suite passed 230/230;
  modern build and production/fallback smoke passed.
- Approximate duration: test:node runner about 16 s including the required
  native rebuild; test body reported 1.16 s.
- Implementation: modern preparation/feature composition uses the existing
  Worker and operation lifecycle; no recognition semantics or page order
  were altered.
- Comments: Worker/lifecycle boundaries and cleanup reasons are documented
  in the modern preparation service/tests.
- Evidence: Node/baseline output, modern build output, and packaged resource
  inspection.

### Workstream 4 — Recognition Workflow

- Commands and results: complete Node/baseline suite passed 230/230,
  including timeout/retry/progress/error/normalization assertions; modern
  component suite passed 7/7 files.
- Implementation: no provider, prompt, OCR, cancellation, timeout, retry,
  concurrency, or progress contract was changed.
- Compatibility: exact baseline recognition, provider redaction, and AppError
  behavior remain green.
- Evidence: npm test output and baseline-recognition/baseline-contracts
  tests.

### Workstream 5 — Metadata and Tasks

- Commands and results: complete Node/baseline suite passed 230/230,
  including Kinefinity/canonical normalization, SQLite ownership,
  autosave, task retention, and legacy migration; copied version-1 E2E
  passed.
- Implementation: Main/SQLite remains authoritative; no schema, filename,
  persistence, task snapshot, or migration format was changed.
- Evidence: baseline-persistence.test.mjs, migration fixtures, and the
  copied version-1 E2E result.

### Workstream 6 — Typed CSV Core and Worker

- Commands and results: baseline CSV suite passed, including exact bytes
  and deliberate one-byte mutation failure; Worker transfer/lifecycle/
  failure tests passed; modern CSV Worker component tests passed.
- Performance: synthetic 10,000-row encoder produced 260,027 bytes in
  17.267917 ms in the final aggregate run, below the 1,000 ms checkpoint.
- Compatibility: CSV encoding/BOM/newline/delimiter/Comments/matching and
  typed-array subview behavior remained unchanged.
- Comments: Worker ownership, transfer ranges, task-vs-infrastructure error
  handling, and cleanup lifecycle are documented in the Worker service/tests.
- Evidence: virtual-table-performance.json, baseline-csv.test.mjs, and
  csv-worker-service.test.ts.

### Workstream 7 — Virtual Table, Editing, and Export

- Commands and results: final Electron synthetic 10,000-row run passed;
  component suite passed 7 files/15 tests.
- Performance: initial DOM rows 24, scrolled DOM rows 37, scroll observation
  7.078417 ms, keyboard edit 20.503708 ms; all below the package thresholds.
- Compatibility: exact export bytes and sparse edit behavior remained in the
  Worker-owned encoder; no Renderer CSV computation path was added.
- Comments: row identity, virtualization, focus retention, and Worker
  ownership comments are present in the table/service implementation.
- Evidence: virtual-table-performance.json and E2E performance marker.

### Workstream 8 — Integration, Production Cutover, E2E, and Visual Baseline

- Commands and results:
  - npm run build:modern (0), npm run build:storybook (0).
  - npm run test:native:abi (0): Electron modules 148 and Node modules 137,
    SQLite 3.53.2, both row probes passed.
  - npm run test:electron:smoke (0) in escalated desktop session:
    modern default, explicit legacy, missing modern, and load-failure
    fallback completed.
  - npm run test:electron:package-smoke (0) in escalated desktop session.
  - CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir (0);
    signing skipped exactly as required.
  - npm run test:e2e (0): 6/6 passed, including two fresh runs and copied
    version-1 Library.
  - Two isolated visual captures (0 each) plus compare script (0):
    10/10 exact PNG SHA-256 matches.
- Visual/a11y: final states cover 1440x900 and 960x600, light/dark,
  compact, dialog, validation error, archived, reduced motion, keyboard,
  ARIA, focus restoration, route scroll, and contrast. Manual review used
  final run-25 images; no placeholder screenshot.
- Evidence: VISUAL-ACCESSIBILITY-REVIEW.md, visual-stability.json,
  PACKAGE-SECURITY-INSPECTION.md, production-smoke.json, and
  packaged-smoke.json.

### Workstream 9 — Manifest-Limited Cleanup

- Before any cleanup, CONTINUOUS_CLEANUP_MANIFEST.md was created and
  Decision Queue entry IP-03-08-CONTINUOUS-CLEANUP-001 was appended.
- Exact deletion set: empty. No file, symbol, dependency, route, IPC,
  style, asset, test, generated path, or comment was deleted.
- Commands and results: node test-support/refactor/verify-ip0308-scope.mjs
  (0, final changed=527, deleted=0, manifestDeletions=0,
  lockfile=exact-root-match); git diff --check (0); final direct dependency
  and lock-root comparison (exact); ORPHAN-AUDIT.md completed.
- Post-manifest final validations were rerun, including clean npm ci,
  check/typecheck, full tests, builds, E2E, package, visual comparison,
  and security inspection.
- Reason for retaining legacy/fallback/migration/evidence assets: each has
  a live production, compatibility, package, migration, or evidence
  reference; see the path/symbol table in the manifest.

## Final Acceptance Matrix

| # | Required validation | Exit | Duration / result | Evidence |
| ---: | --- | :---: | --- | --- |
| 0 | Initial and final current-state authority verifier | 0 | Initial passed; final run is the handoff command | verify-current-state.mjs output |
| 1 | Clean npm ci | 0 | 541 packages; npm reports 7 s install | this ledger and install output |
| 2 | npm run check plus Python syntax check | 0 | about 0.7 s | package syntax inventory and command output |
| 3 | npm run typecheck | 0 | about 0.25 s | command output |
| 4 | Complete Node/baseline suite | 0 | 230/230; no skip/todo; about 16 s including native rebuild | npm test:node output |
| 5 | Complete modern Vitest/component suite | 0 | 7 files/15 tests; about 0.7 s | npm run test:component output |
| 6 | Aggregate npm test | 0 | Node 230/230 plus modern 7/7; no skip/todo | npm test output |
| 7 | Main/Preload/Renderer/Storybook builds | 0 | modern and Storybook outputs completed | build output and package inspection |
| 8 | Development/production/fallback/packaged smoke | 0 | all required modes passed in escalated desktop session | production-smoke.json and packaged-smoke.json |
| 9 | Playwright Electron E2E | 0 | 6/6; two fresh, one copied version-1, Worker, 10k, a11y | test-results and E2E output |
| 10 | Unsigned directory package | 0 | electron-builder 26.15.3; signing skipped | PACKAGE-SECURITY-INSPECTION.md |
| 11 | Gate-00 compatibility tests | 0 | baseline contracts/recognition/CSV/persistence/visual passed | baseline tests |
| 12 | Exact CSV bytes and mutation failure | 0 | byte goldens and intentional one-byte mismatch both passed | baseline-csv.test.mjs |
| 13 | Worker transfer/memory/lifecycle/failure | 0 | transfer, typed subview, clear, termination, task/infrastructure errors passed | baseline-csv and Worker tests |
| 14 | 10,000-row virtualization/edit/export | 0 | 24/37 DOM rows; 7.078 ms scroll; 20.504 ms edit; 17.268 ms encode | virtual-table-performance.json |
| 15 | Visual/a11y/focus/contrast/reduced motion | 0 | two captures, 10/10 identical; all documented contrast ratios pass | VISUAL-ACCESSIBILITY-REVIEW.md |
| 16 | Package/security/navigation/native inspection | 0 | 5,523 ASAR entries; zero secret-pattern hits; native resource present | PACKAGE-SECURITY-INSPECTION.md |
| 17 | Version-1 migration/source integrity | 0 | copied Library E2E and baseline source-integrity tests passed | baseline-persistence and E2E |
| 18 | Cleanup verifier/orphan/lock/diff/scope | 0 | empty deletion set; scope and lock exact; diff check clean | manifest, ORPHAN-AUDIT.md, scope output |

## Known environment observations

- Sandbox GUI launches repeatedly failed before the app main process with a
  macOS LaunchServices Electron SIGABRT; the same smoke passed in the
  escalated desktop session. The failure was recorded as an environment
  launch condition, not accepted as product evidence.
- Storybook cannot write the global settings file under
  /Users/rasteaks/.storybook in this managed workspace; Storybook build still
  completed successfully.
- The inherited gateway-performance command cannot rewrite protected
  Gate-01/02 evidence/IP-02/performance.json under sandbox permissions. The
  Gate evidence remains untouched; modern 10,000-row performance evidence is
  independently recorded here.
- npm emits existing deprecation warnings and reports audit vulnerabilities
  during clean install. No audit fix or opportunistic dependency upgrade was
  performed.
- No full hardware FPS trace is claimed; the real Electron scroll/edit
  observations and DOM-row threshold are recorded for independent Sol rerun.

## C01 resumed final-handoff rerun — 2026-08-21

- The C01 governance repair was run against the preserved Gate-01/02 dirty
  worktree. `npm ci --no-audit --no-fund`, `npm run check`,
  `npm run typecheck`, final Node/baseline, component, and aggregate tests all
  exited 0. Final Node/baseline was 230/230; component was 7 files/15 tests;
  aggregate was Node 230/230 plus modern 7 files/15 tests.
- `npm run build:modern`, `npm run build:storybook`,
  `npm run test:native:abi`, `npm run test:electron:smoke`,
  `npm run test:electron:package-smoke`, and
  `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir` exited 0.
  Storybook's existing managed-global-settings EPERM and chunk warning remain
  documented observations.
- The first direct E2E invocation after packaged smoke reached no window
  because the shared native addon had been restored to Node ABI. The existing
  Electron rebuild was then run and the unchanged `npm run test:e2e` exited 0
  with 6/6: two fresh profiles, copied version-1 Library, Worker, 10,000-row
  virtualization/edit, and keyboard/ARIA/reduced-motion/route-scroll.
- Two new isolated visual captures under
  `final-handoff/visual-rerun-1` and `visual-rerun-2` exited 0; a read-only
  comparison found 10/10 identical PNG SHA-256 pairs. No existing visual
  evidence was overwritten.
- Final `npm run test:native:abi`, `npm run test:node`, and `npm test` exited 0
  after all Electron operations, proving Node ABI restoration.
- Complete command, environment, exit, and evidence mapping is in
  `final-handoff/ACCEPTANCE-RERUNS.md`.

## C02 corrected checkpoint ledger — 2026-08-22

This section supersedes earlier counts and overclaims without deleting the
historical record.

### Corrected functional checkpoints

- Task lifecycle: immediate edit→switch flush, A→B absent-state clearing,
  retained Worker prime, relaunch-compatible task load, new/delete and visible
  save/retry passed in Electron E2E. Cross-scope stale-save/retry behavior also
  passed focused unit tests.
- CSV: retained processor owns canonical key extraction, Resolve/slate decode,
  provider-free record conversion and exact export. Baseline byte goldens,
  transfer subviews, task/infrastructure errors, termination and clear passed.
- Preparation: direct PDF and image paths use the typed Worker; 21-page and
  corrupt PDF errors, valid one-page PDF, removal/unmount and zero remaining
  Workers passed. Focused tests enforce ten UI commits/second and pending timer
  cleanup.
- Project/task load: one parallel Main authority read supplies project,
  scenarios and task summaries; route/project publication is one React commit.
  No Renderer persistence or second writer was added.

### Corrected final acceptance matrix

| Validation | Final result |
| --- | --- |
| `npm ci --no-audit --no-fund` | PASS; 540 packages; lock root exact |
| `npm run check`, Python syntax, `npm run typecheck` | PASS |
| Node/baseline and aggregate | PASS; 232/232, zero fail/skip/todo |
| Modern/component | PASS; 8 files/19 tests, zero fail/skip/todo |
| Main/Preload/Renderer and Storybook builds | PASS |
| Electron E2E | PASS; 10/10 in explicit temporary Libraries |
| 10k Worker/heap/virtualization | PASS; see `c02-performance-memory.json` |
| 500 projects/1,000 tasks/FPS/long tasks | PASS; 119.83 FPS, no >50 ms long task |
| Legacy/modern task/project switch | PASS three consecutive runs at 1,000-summary/500-row workload |
| Production modern/legacy/fallback smoke | PASS; 5+5 start samples, medians 168.2/169.0 ms |
| Final visual pair | PASS; 14/14 byte-identical |
| Unsigned directory build | PASS; signing skipped by required policy |
| Packaged smoke/package/security | PASS; ASAR 5,524 entries, credential counts zero |
| Native ABI lifecycle | PASS; Electron 148 → Node 137 restored |
| Version-1 copied migration/source integrity | PASS; temporary copy only |
| Cleanup/scope/diff | PASS; zero deletion; `.gitignore` baseline restored |

### C02 stop disposition

All technical checkpoints pass. `IP-03-08-SAFETY-ISOLATION-001` remains the
only blocking decision because the earlier real-Library row impact is
unprovable and the owner has not yet explicitly accepted/confirmed it. C03
authorizes governance disposition only; no further code change is requested.
