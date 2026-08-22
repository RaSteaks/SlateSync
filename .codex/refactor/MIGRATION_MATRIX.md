# SlateSync Migration Matrix (post Gate 01-02)

Authority status: **CURRENT SUPPORTING MATRIX FOR CONTINUOUS PACKAGE VERSION
2026-08-21.2**. Workstream labels below are not separate packages or Gates.

This matrix separates the approved foundation from the remaining continuous
migration. Gate 01-02 froze the build, typed contract, compiled Preload, and
sole `window.slateSync` gateway. The IP-03～IP-08 labels are requirement-lineage
inside `IP-03-08-CONTINUOUS.md`, not separate authorization or review borders.

| Current area | Current owner / files | Approved/current evidence | Protected behavior | Continuous workstream lineage |
| --- | --- | --- | --- | --- |
| Electron lifecycle and window | Main: `electron/main.mjs` | Gate 01-02 production/package smoke; `contracts/electron.json` | entrypoint, sandbox/security flags, navigation boundary, one Renderer | Foundation approved; production cutover in integration workstream |
| Preload gateway | compiled `out/preload/index.cjs`; source `src/preload/**`; `electron/preload.cjs` marker | Shared Contract v1, 27-operation parity, package smoke | sole `window.slateSync`, Result/AppError, progress cleanup, exact binary ranges | Foundation approved; legacy adapter removed only by exact cleanup manifest |
| IPC handlers | `electron/ipc-handlers.mjs` | exact typed mapping and existing IPC tests | raw channels, project write leases, recognition persistence | Frozen; no continuous contract change |
| Provider configuration/secrets | `lib/config.mjs`, `electron/key-store.mjs`, `electron/env-loader.mjs` | `contracts/environment.json`, `contracts/providers.json` | provider routing, public redaction, env ranges/defaults | IP-02 |
| Recognition orchestration | `lib/ai-client.mjs`, `lib/schema.mjs` | recognition fixtures/tests, compatibility contract | prompts, schemas, page order, inheritance, audit/review, timeout/retry/concurrency | IP-05B |
| OCR evidence | `lib/ocr/**`, OCR scripts | existing OCR tests and compatibility contract | optional/required fallback, cache, direct-PDF behavior | IP-05B |
| Slate/PDF preparation | `public/app.js`, `public/image-preprocess.js` | visual states and existing preparation tests | page grouping, previews, yielding, cancellation/lifecycle behavior | IP-05A |
| Project Library | `lib/project-library.mjs`, transfer/runtime modules | persistence fixtures/schema inventory | package tree, versions, project isolation, archive/import/export/relaunch | IP-04 |
| SQLite/task/diagnostic persistence | Main: `lib/sqlite-store.mjs`, `lib/task-store.mjs`, `lib/diagnostics.mjs`; `better-sqlite3` | schema inventory, persistence fixtures/tests, native ABI lifecycle | driver during refactor, filenames, schemas, WAL/pragmas, JSON snapshots, migration marker | Metadata/tasks and integration only; driver evaluation deferred by ADR |
| Scenario profiles | `lib/scenario/**` | existing scenario tests and project DB schema | project ownership, fingerprint/schema versions, persistence | IP-05C |
| Metadata scanning | `public/metadata-*.js`, `electron/slate-scanner.mjs` | existing metadata/scanner tests | canonical metadata shape, directory safety and depth | IP-05C |
| CSV algorithms | `public/resolve-csv.js` | CSV golden fixtures/tests | decoding, merge, normalization, encode, output bytes | IP-06A then IP-06C |
| CSV Worker/client | `public/csv-worker*.js`, `public/csv-background-tasks.js` | Worker transfer/fallback golden tests | table retention, transferable bytes, fallback and lifecycle | IP-06A |
| CSV preview/edit/export UI | `public/app.js`, `public/task-persistence.js` | visual states, task snapshot fixture | manual sparse edits, result tabs, export/save dialog, restore | IP-06B/IP-06C |
| C02 modern task/preparation correction | modern Renderer adapters over retained public modules | 10/10 isolated E2E, exact-byte baselines, copied v1 Library, 14-state stable visual pair | no schema/format migration; atomic projection restore, Worker prime/clear, image/PDF parity and resource release only | COMPLETE; quarantined default Library remains outside migration scope |
| Renderer routes/state | `public/app.js`, `public/index.html`, `public/styles.css` | ten visual snapshots | projects/workspace/settings routes and current UI state machine | IP-04 through IP-07 |
| Machine settings and keys | `electron/settings-store.mjs`, `electron/key-store.mjs` | environment/persistence contract | userData paths, fields, atomic writes, permissions, secret ownership | IP-04/IP-05C |
| Packaging and release | `package.json`, `electron-builder.yml`, `.github/**`, build assets | unsigned package smoke, strict build, Node/Electron native ABI probe | app identity, resource inputs, architectures, signing/publishing semantics | Additive continuous validation; exact cleanup only |

IP-0102 added the one typed compatibility boundary but did not migrate business
ownership or persistence. Existing SQLite formats remain frozen inputs. The
continuous package must end with one production Renderer and may remove legacy
adapters only through its path/symbol-exact Cleanup Manifest.
