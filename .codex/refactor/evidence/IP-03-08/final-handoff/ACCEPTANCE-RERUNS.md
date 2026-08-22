# C01 Final-Handoff Acceptance Reruns

Recorded: 2026-08-21 (Asia/Shanghai)

## Environment

- HEAD: `c7dafa4d972e5eb7be61f00e2b546d6826e70c87`
- Branch: `codex/react-architecture-refactor`
- Host/runtime: macOS arm64; Node `v24.13.0`; npm `11.6.2`;
  Electron `43.3.0`; Storybook `10.5.10`; Vitest `4.1.11`; Playwright
  `1.62.1`.
- Active package: `IP-03-08-CONTINUOUS` `2026-08-21.2`;
  SHA-256 `67a4d98e90950a78a04e4ab2b5a6b6a164408567dee83f6d211b2b4e54a2c164`.
- Electron/E2E/visual/package commands used isolated temporary `userData` and
  explicit temporary `libraryPath`; no provider key or live Project Library
  was used.
- No Git index/history mutation occurred.

## Required command results

| Command | Exit | Result / duration observation | Raw or supporting evidence |
| --- | :---: | --- | --- |
| `node .codex/refactor/verify-current-state.mjs` before reconciliation | 0 | `REFACTOR_AUTHORITY_OK`, package version/SHA exact | terminal output; final rerun after reconciliation below |
| `npm ci --no-audit --no-fund` | 0 | 541 packages; npm reported 7s; existing deprecation warnings only | install output; `package-lock.json` exact-root check |
| `npm run check` | 0 | Node syntax and Python AST checks passed | terminal output |
| `npm run typecheck` | 0 | TypeScript project references passed | terminal output |
| `npm run test:node` | 0 | 230 passed, 0 failed/skipped/todo; final post-Electron Node run | terminal output; baseline tests |
| `npm run test:component` | 0 | 7 files / 15 tests passed; Worker encoder 10,000 rows, 17.846ms / 260027 bytes | terminal output |
| `npm test` | 0 | final aggregate: Node 230/230 plus modern 7 files/15 tests; final post-Electron run | terminal output |
| `npm run build:modern` | 0 | Main, Preload, Renderer built; Renderer JS 344.53kB gzip 104.89kB; CSS 31.97kB gzip 6.26kB; Worker 463.80kB | `out/**`; terminal output |
| `npm run build:storybook` | 0 | Storybook completed; managed workspace EPERM global-settings warning and existing chunk warning retained | `storybook-static/**`; terminal output |
| `npm run test:native:abi` | 0 | Electron modules 148 / Node modules 137; SQLite 3.53.2; both probes passed; final Node restoration passed | terminal output |
| `npm run test:electron:smoke` | 0 | Development smoke command passed in escalated desktop session; existing evidence covers modern, explicit legacy, missing-modern and load-failure fallback | `production-smoke.json`; terminal output |
| `npm run test:electron:package-smoke` | 0 | Packaged smoke passed in isolated desktop session | `packaged-smoke.json`; terminal output |
| `npm run test:e2e` after existing `npm run rebuild:native:electron` | 0 | 6/6 passed: fresh 932/558ms, version-1 1.1s, Worker 670ms, 10k 626ms, a11y 729ms | `test-results/**`; terminal output |
| `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir` | 0 | Electron Builder 26.15.3; unsigned directory package; signing explicitly skipped | `dist/mac-arm64/SlateSync.app`; `PACKAGE-SECURITY-INSPECTION.md` |
| Gate-00 contract/recognition/CSV/persistence/visual tests | 0 | Included in final 230-test Node/baseline suite | baseline test files; terminal output |
| exact CSV bytes and deliberate one-byte mutation | 0 | Included and passed in `baseline-csv.test.mjs` | `test/baseline-csv.test.mjs` |
| Worker transfer/memory/lifecycle/failure | 0 | Included and passed in baseline + modern suites; typed subview exact-range case passed | baseline/modern tests |
| 10,000-row virtualization/edit/export | 0 | DOM 24→37; final E2E scroll 10.989ms, edit 19.056ms; encoder 17.812ms in final aggregate | `virtual-table-performance.json`; E2E marker; component output |
| two visual captures plus hash comparison | 0 | 10 PNGs per run; 10/10 exact SHA-256 matches | `final-handoff/visual-rerun-1`, `visual-rerun-2`; `VISUAL-STABILITY-RERUN.md` |
| version-1 migration/source integrity | 0 | Copied version-1 Library E2E and baseline persistence/source-integrity tests passed | E2E output; `test/baseline-persistence.test.mjs` |
| package/security/navigation/secret/native inspection | 0 | ASAR 5,523 entries; required resources present; packaged smoke passed; no credential-shaped value in final package scan | `PACKAGE-SECURITY-INSPECTION.md`; ASAR inspection |
| cleanup/orphan/lock/scope/diff checks | 0 | Empty deletion set; scope `changed=556` before final evidence additions and `changed=560` after them, both `deleted=0`; lock root exact; diff check clean | `CONTINUOUS_CLEANUP_MANIFEST.md`; `ORPHAN-AUDIT.md`; `POST_CORRECTION_INVENTORY.md` |

## Native ABI and E2E precondition observation

The first direct `npm run test:e2e` invocation after packaged smoke exited 1
before `firstWindow()` because packaged smoke had restored the shared native
module to Node ABI. No assertion or application behavior was reached. The
existing Electron rebuild lifecycle was then run, followed by the unchanged
exact `npm run test:e2e`, which passed all six tests. This diagnostic is kept
truthful; no production/test fix or manual `.node` copy was used. The final
post-Electron `npm run test:native:abi`, `npm run test:node`, and `npm test`
prove Node restoration.

## Visual rerun

- First capture: `SLATESYNC_VISUAL_OUTPUT=.codex/refactor/evidence/IP-03-08/final-handoff/visual-rerun-1 node test-support/e2e/capture-visual-baseline.mjs`, exit 0.
- Second capture: `SLATESYNC_VISUAL_OUTPUT=.codex/refactor/evidence/IP-03-08/final-handoff/visual-rerun-2 node test-support/e2e/capture-visual-baseline.mjs`, exit 0.
- Read-only hash comparison: 20 PNG files total, 10 matching pairs, exit 0;
  output `FINAL_HANDOFF_VISUAL_STABILITY_OK 10`.
- Manual review: dark dialog, light 960×600 global settings, and dark
  1440×900 reduced-motion workspace showed no clipping or placeholder image.

## Scope and data safety

- No deletion occurred; Cleanup Manifest deletion/replacement sets remain
  empty.
- No default macOS Project Library was opened, parsed, copied, migrated,
  archived, deleted, hashed, or rewritten after the quarantine decision.
- The only code edits made during this resumed handoff are governance verifier
  comments/allowlist entries needed to validate the two documented authority
  phases. Production source, IPC, Worker, database, migration, CSV, package
  configuration, test assertions, and lockfile contents were not changed.
