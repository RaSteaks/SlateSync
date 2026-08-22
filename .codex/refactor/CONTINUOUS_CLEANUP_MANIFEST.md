# IP-03—IP-08 Continuous Cleanup Manifest

Recorded: 2026-08-21 (Asia/Shanghai)

## Scope and disposition

- Authority: .codex/refactor/packages/IP-03-08-CONTINUOUS.md
- Authority version: 2026-08-21.2
- Authority SHA-256: 67a4d98e90950a78a04e4ab2b5a6b6a164408567dee83f6d211b2b4e54a2c164
- Baseline: HEAD c7dafa4d972e5eb7be61f00e2b546d6826e70c87, with the Gate-01/02 dirty worktree preserved.
- Exact deletion set: EMPTY.
- Exact replacement set: EMPTY.
- Lockfile removals: NONE.
- Cleanup is intentionally a no-op because every reviewed legacy, fallback, migration,
  compatibility, package, or generated item below still has a live reference, an
  acceptance/evidence role, or an unresolved ownership/data-safety dependency.

No directory, filename pattern, symbol family, dependency category, route, IPC
channel, style family, asset family, test family, or comment category is an
implicit authorization to delete. Any future deletion requires a new
path/symbol-exact manifest entry and a fresh review.

## Exact audited items retained

### Production entry and bounded fallback

| Exact path / symbol | Pre-cleanup reference | Runtime or compatibility reason | Action | Rollback effect |
| --- | --- | --- | --- | --- |
| electron/main.mjs#selectRendererEntry | electron/main.mjs:226-251; test/refactor/ip-01/skeleton.test.ts | Modern default, explicit legacy switch, and missing/corrupt modern recovery are production behavior. | Retain | Keeps the bounded one-Renderer recovery path. |
| electron/main.mjs#legacyRoot | electron/main.mjs:222-250,303-310; packaged smoke evidence | Legacy root remains the approved recovery and compatibility root. | Retain | Removing it would invalidate rollback/package smoke. |
| electron/preload.cjs | test/baseline-contracts.test.mjs:62; Gate-01/02 preload decision | Historical sandbox transition marker and protected one-Preload boundary. | Retain | No change to approved preload loading semantics. |
| public/index.html | electron/main.mjs:249,309; legacy smoke | Legacy renderer fallback entry. | Retain | Preserves fallback launch. |
| public/app.js#fallbackCsvProcessor | public/app.js:84,1678-1686,3600-3617; test/csv-worker-client.test.mjs | The authorized Worker-failure compatibility path remains required while fallback exists. | Retain | Preserves task-error and infrastructure fallback behavior. |
| public/csv-worker.js#self.onmessage | public/csv-worker-client.js:5; src/renderer/services/csv-worker-service.ts:52 | Worker protocol and legacy bridge share this production worker resource. | Retain | Preserves worker-owned CSV computation. |
| public/csv-worker-client.js#createCsvWorkerClient | public/app.js:26; test/baseline-csv.test.mjs | Frozen compatibility client and transfer/lifecycle tests reference it. | Retain | Avoids a second CSV implementation or protocol drift. |

### Migration, version-1 data, and protected compatibility

| Exact path / symbol | Pre-cleanup reference | Runtime or data reason | Action | Rollback effect |
| --- | --- | --- | --- | --- |
| lib/project-library.mjs#migrateLegacyData | test/baseline-persistence.test.mjs:154-176; test/project-library.test.mjs:246-276 | Version-1 Library/task migration and source-integrity behavior. | Retain | Preserves copied-library migration. |
| test/fixtures/baseline/persistence/legacy-migration.json | test/baseline-persistence.test.mjs:158 | Gate-00/version-1 migration fixture. | Retain | Keeps source-data compatibility proof. |
| src/shared/contracts/index.ts#LegacyUsageVariant | src/shared/contracts/index.ts:482; contract tests | Shared Contract v1 retains legacy snapshot/DTO compatibility. | Retain | Prevents DTO/format regressions. |
| public/electron-bridge.js#legacyError | public/electron-bridge.js:11-23; test/electron-bridge.test.mjs | Sole legacy adapter for the existing slateSync gateway. | Retain | Preserves all 27 operation mappings. |

### Worker, PDF, native, and package resources

| Exact path / symbol | Pre-cleanup reference | Package/runtime reason | Action | Rollback effect |
| --- | --- | --- | --- | --- |
| public/vendor/pdfjs/pdf.mjs | public/app.js:77; packaged ASAR inspection | Legacy PDF preparation and packaged resource. | Retain | Preserves PDF behavior and package contents. |
| public/vendor/pdfjs/pdf.worker.mjs | public/app.js:79; package build input | PDF worker resource. | Retain | Preserves off-main-thread PDF preparation. |
| src/renderer/workers/preparation.worker.ts#preparePdf | src/renderer/workers/preparation.worker.ts:1-40; modern build | Modern PDF Worker path. | Retain | Keeps Worker ownership and lifecycle. |
| node_modules/better-sqlite3/build/Release/better_sqlite3.node | Native ABI lifecycle test and package inspection | Existing better-sqlite3 runtime; driver migration is protected. | Retain | Keeps Node/Electron ABI lifecycle intact. |
| node_modules/@napi-rs/canvas-darwin-arm64 | Packaged native-resource inspection | Existing optional canvas package resource. | Retain | Avoids packaging/runtime ABI regression. |
| node_modules/@tybys/wasm-util | npm ls --depth=0 and dependency tree | Transitive native/package resource; not a direct dependency removal target. | Retain | Keeps package resolution deterministic. |
| scripts/copy-pdfjs.mjs | package.json#postinstall; clean-install output | Automatic postinstall resource preparation. | Retain | Preserves clean-install/package lifecycle. |

### Test, evidence, generated, and visual assets

| Exact path / symbol | Pre-cleanup reference | Evidence reason | Action | Rollback effect |
| --- | --- | --- | --- | --- |
| test/baseline-contracts.test.mjs | npm run test:node; Gate-00 contract checkpoint | Frozen compatibility assertions. | Retain | No weakening of baseline coverage. |
| test/baseline-csv.test.mjs | npm run test:node; exact-byte/Worker checkpoint | Transfer, task-error, mutation, and byte evidence. | Retain | Keeps byte-semantic proof. |
| test/baseline-persistence.test.mjs | npm run test:node; migration checkpoint | Version-1 source-integrity proof. | Retain | Keeps migration proof. |
| test/baseline-recognition.test.mjs | npm run test:node; recognition checkpoint | Recognition compatibility proof. | Retain | Keeps recognition behavior proof. |
| test/baseline-visual.test.mjs | npm run test:node; frozen baseline | Historical visual compatibility assertion. | Retain | Keeps Gate visual regression proof. |
| test-support/refactor/legacy-test-gateway.mjs#installLegacyTestGateway | package.json#test:node; baseline suite | Test-only compatibility injection, not a production hook. | Retain | Keeps deterministic Node baseline execution. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-1 | Visual incident record | Safety/isolation incident evidence. | Retain | Preserves audit trail. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-2 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-3 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-4 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-5 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-6 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-7 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-8 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-9 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-10 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-11 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-12 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-13 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-14 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-15 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-16 | Visual capture history | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-17 | Visual readiness iteration | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-18 | Stable-pair predecessor evidence | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-19 | Focus-readiness iteration | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-20 | Focus-readiness iteration | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-21 | Drift diagnosis evidence | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-22 | Drift diagnosis evidence. | Capture iteration evidence. | Retain | Preserves reproducibility history. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-23 | VISUAL-ACCESSIBILITY-REVIEW.md; final stable pair | Final human-reviewed capture. | Retain | Final visual evidence remains inspectable. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-24 | visual-stability.json; final stable pair | Independent stable rerun/hash capture. | Retain | Stable rerun remains reproducible. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-25 | visual-stability.json; final post-cleanup stable pair | Final post-cleanup human-reviewed capture. | Retain | Final visual evidence remains inspectable. |
| .codex/refactor/evidence/IP-03-08/visual-contained-run-26 | visual-stability.json; final post-cleanup stable pair | Independent final post-cleanup hash capture. | Retain | Stable rerun remains reproducible. |
| storybook-static | npm run build:storybook; package evidence | Build artifact used for Storybook verification. | Retain | No unverified artifact deletion. |
| test-results | Playwright runner | E2E runner output and failure diagnostics. | Retain | Keeps test traceability. |
| dist/mac-arm64/SlateSync.app | Unsigned directory package and packaged smoke | Package inspection/smoke artifact. | Retain | Keeps packaged validation artifact. |
| dist/mac/SlateSync.app | Existing package output | Existing user/worktree artifact not proven disposable in this run. | Retain | Avoids unrelated artifact mutation. |
| scripts/__pycache__/paddleocr_runner.cpython-39.pyc | Python check runtime | Generated local validation output; this exact file is not authorized for deletion. | Retain | No broad generated-file deletion. |

## Verification and rollback

- Reference evidence was collected with rg over electron, src, public, test,
  test-support, .storybook, package.json, and electron-builder.yml; the
  complete audit is recorded in .codex/refactor/evidence/IP-03-08/ORPHAN-AUDIT.md.
- Since the exact deletion set is empty, there is no pre/post source removal
  delta and no lockfile-removal delta to reconcile.
- The default macOS Project Library remains quarantined per
  .codex/refactor/evidence/IP-03-08/LIBRARY-IMPACT-AUDIT.md; this manifest
  authorizes no operation against it.
- If Sol later authorizes a deletion, the implementation must add the exact
  path and symbol here, record references and replacement coverage, run the
  full Final Acceptance Matrix, and retain this no-op record as the prior
  disposition.
