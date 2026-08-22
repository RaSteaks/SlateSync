# SlateSync Continuous Implementation Package IP-03-08

STATUS: **AUTHORIZED — Gate 01-02 approved; executable as one continuous task**

PACKAGE VERSION: **2026-08-21.2 — current**

AUTHORITY INDEX: `.codex/refactor/README.md` and
`.codex/refactor/CURRENT_STATE.json`

OWNER AUTHORIZATION: Replace the former independent IP-03, IP-04, IP-05A/B/C, IP-06A/B/C, IP-07, and IP-08 construction boundaries with one continuous Luna implementation.

IMPLEMENTER: GPT-5.6 Luna XHigh

FINAL REVIEWER: GPT-5.6 Sol High

REVIEW TARGET: `.codex/refactor/reviews/FINAL-IP-03-08.md`

GENERATED: 2026-08-20  
AUTHORIZED: 2026-08-21 by `reviews/GATE-01-02.md` (`APPROVED`)

## Authority and Supersession

This file is the sole implementation authority for all work historically described as IP-03 through IP-08. The corresponding sections in `IP-01——IP-08.md` remain requirement provenance only and are not executable packages. Their former individual authorization boundaries, protected-scope handoffs, local freezes, Gate 03-04, Gate 05A-C, Gate 06A, Gate 06B-C, Gate 07, Gate 08, and stage-stop instructions are superseded by this package.

No other file under `.codex/refactor/packages/` may expand, narrow, pause, or
split this authorization. Historical package text is usable only to verify
that a requirement was carried forward into this version.

The following remain fully binding:

- `.codex/refactor/ARCHITECTURE_INVARIANTS.md`
- `.codex/refactor/COMPATIBILITY_CONTRACT.md`
- `.codex/refactor/DECISION_QUEUE.md`
- the frozen Shared Contract v1 and accepted IP-01/02 build boundaries after Final Gate 01-02
- all baseline, compatibility, migration, security, accessibility, performance, test, build, and data-safety requirements below
- the repository instruction to add/update useful comments after code changes and remove stale comments

Historical IP numbers in this package are traceability labels, not authorization boundaries. Luna does not stop, switch models, request an intermediate Sol review, or wait for a Gate when moving between workstreams. A checkpoint records evidence and guides diagnosis; it is not approval.

## Objective

Complete every remaining architecture, React Renderer, Design System,
feature, Worker, integration, migration-validation, visual, accessibility,
performance, and manifest-limited cleanup requirement formerly assigned to
IP-03 through IP-08 in one Luna XHigh implementation task. Preserve the frozen
foundation and all existing behavior, then hand the complete cumulative diff
and evidence to one Sol High Final Review without an intermediate model switch
or construction Gate.

## Current Repository Facts

At authorization time:

- HEAD is `c7dafa4d972e5eb7be61f00e2b546d6826e70c87` on `codex/react-architecture-refactor`.
- IP-01/IP-02 Correction C01 is complete and Gate 01-02 is `APPROVED`. Shared Contract v1, the single compiled sandbox Preload, sole `window.slateSync` gateway, exact scope evidence, and deterministic native-runtime lifecycle are frozen foundation inputs.
- The approved foundation remains in the dirty worktree relative to the baseline HEAD. Luna must preserve that complete Gate-approved inventory and measure the continuous diff from it; a clean commit is not an admission requirement.
- The repository root has no physical `AGENTS.md`. The active task instruction still requires synchronized comments for non-obvious architecture, ownership, concurrency, compatibility, and lifecycle logic.
- The target build uses Node 22-compatible strict TypeScript, Vite, Vitest, React, Electron 43.3.0, a single compiled CommonJS Preload, and deterministic ignored `out/**` outputs.
- Production still defaults to the complete legacy Renderer. The modern Renderer is an explicit development opt-in until the integration/cutover workstream completes; one BrowserWindow never runs both Renderers.
- `better-sqlite3` remains the approved Main-owned database driver. System Node and Electron prepare their own native ABI through named scripts; tests, smoke controllers, CI, and release validation must never assume one shared binary is loadable by both runtimes. `adr/ADR-DATABASE-RUNTIME-ABI.md` governs any future driver evaluation.
- Production behavior is still the legacy Electron application unless and until the continuous cutover work is completed and validated.
- Apple Development signing and notarization are release-stage concerns. Refactor validation uses `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`; signing, entitlements, publishing, identity, and release-target configuration remain protected.

These facts must be re-read from the actual repository at execution start. They are not permission to ignore later approved IP-01/02 changes.

## Continuous Admission Conditions

Luna may start this package only when all of the following are true:

1. **PASS** — IP-01 and IP-02 Correction C01 completed and Sol approved `.codex/refactor/reviews/GATE-01-02.md` on 2026-08-21.
2. **PASS** — Shared Contract v1 and the build/Preload boundaries are frozen; the Gate closed every IP-0102 Decision Queue blocker, including `IP-0102-PRELOAD-001`.
3. The start HEAD, `git status`, complete diff, generated outputs, active dependencies, and test/build commands are recorded without cleaning, overwriting, staging, or committing user work.
4. **PASS** — Node 229/229, modern 6/6, legacy visual 1/1, production Electron smoke, unsigned packaged smoke, aggregate tests, exact scopes, and diff checks passed in the independent Gate review. The ten stable legacy PNGs are accepted; the modern unified visual baseline remains a final continuous deliverable.
5. The current implementation is reconciled against this package. If Gate 01-02 changed a contract or repository fact assumed here, Luna must use the approved actual state and record the reconciliation. Any material scope or architecture conflict is a Stop Condition.

## Continuous Execution Contract

1. Execute the ordered workstreams in one Luna task. Preserve dependency order, but treat the old IP labels only as provenance.
2. Use the union Allowed Scope in this package. Luna may revisit an earlier workstream's files when later integration exposes a defect, provided the change remains inside this package and is documented in the evidence ledger.
3. Run the focused checkpoint after each workstream and record commands, results, changed files, comments, compatibility observations, and performance evidence. Continue without a Sol handoff when the checkpoint passes.
4. A checkpoint failure is not automatically a Gate. Diagnose and repair an in-scope implementation defect, then rerun it. Continue other independent work while a non-safety defect is being resolved only when doing so cannot hide, compound, or invalidate the failure.
5. Stop only for a package Stop Condition involving an unresolved architecture decision, contract change, data-loss/corruption risk, security boundary, unprovable compatibility, unapproved dependency, or an acceptance failure that cannot be safely corrected inside this package.
6. Record decisions and unresolved conflicts in `.codex/refactor/DECISION_QUEUE.md`. Non-blocking items do not stop unrelated work. Blocking items stop only when further implementation would prejudge or compound the decision.
7. Do not weaken, skip, delete, mark todo/only, auto-update, or replace a test/golden to obtain a pass. Do not fabricate screenshots, performance measurements, or migration evidence.
8. Do not commit, stage, push, switch branches, reset, clean untracked files, delete user data, use real credentials, or operate on a user's active Project Library.
9. After all workstreams, run the complete final validation matrix, create the Continuous Completion Report, and stop for Sol Final Review.
10. Sol's only verdicts are `APPROVED` and `CHANGES REQUIRED`. Luna does not declare the refactor complete.
11. Do not pause or switch models merely because a historical IP number changes. The only planned handoff is Luna XHigh to Sol High after the complete Continuous Completion Report; a true Stop Condition is the sole exception.

## Allowed Scope

The continuous package may modify or add only the following, subject to the Protected Scope and cleanup rules:

- `src/main/**`, `src/preload/**`, `src/shared/**`, `src/renderer/**`
- `.storybook/**`, `playwright*.config.*`, `test/e2e/**`, `test-support/e2e/**`
- modern unit/component/story/test helpers and fixtures under `src/**`, `test/refactor/**`, `test-support/refactor/**`, and `test/fixtures/refactor/**`
- `package.json`, `package-lock.json`, TypeScript/Vite/Vitest configuration, and approved scripts needed for the authorized dependencies and validation
- `electron/main.mjs` only for typed composition, modern production entry, bounded legacy rollback, and package-safe lifecycle integration
- `electron-builder.yml` and `.github/workflows/ci.yml` / `release.yml` only for additive modern build, test, E2E, and package validation; identity, targets, signing, notarization, publishing, permissions, secrets, and release semantics are protected
- `public/image-preprocess.js`, `public/recognition-request.js`, `public/resolve-csv.js`, `public/csv-background-tasks.js`, `public/csv-worker.js`, `public/csv-worker-client.js`, `public/task-persistence.js`, and other legacy sources only for a measured single-source adapter, compatibility marker, or a path/symbol-exact cleanup item
- existing tests only to strengthen coverage or append approved transition assertions; historical compatibility assertions and expected behavior may not be removed or relaxed
- `.codex/refactor/COMPATIBILITY_CONTRACT.md`, `MIGRATION_MATRIX.md`, ADRs, evidence, visual baselines, Decision Queue, and the Continuous Cleanup Manifest to record actual implementation facts

Authorized dependencies for their stated roles:

- Runtime: `lucide-react`, `zustand`, `@tanstack/react-table`, `@tanstack/react-virtual`
- Development: `storybook`, `@storybook/react-vite`, `@storybook/addon-a11y`, `@playwright/test`

Install direct dependencies at exact versions compatible with Node 22, Electron 43.3.0, the approved React/Vite toolchain, and the current lockfile. Substitution, additional dependencies, plugins, routers, state libraries, CSV libraries, or UI kits require a blocking Decision Queue decision.

## Protected Scope

Unless this package explicitly states otherwise, Luna must not change:

- Architecture Invariants, Shared Contract v1, Result/AppError semantics, domain ownership, raw IPC transport behavior, or the one-Preload-gateway rule
- recognition algorithms, prompts, schemas, provider/OCR routing, timeout/retry/concurrency/cancellation semantics, page order, audit/review stages, progress meaning, or persistence timing
- CSV decode/merge/normalize/encode semantics, exact output bytes, encoding/BOM/newline/delimiter behavior, row/column order, matching/conflict rules, field widths, Comments allowlist, sparse edits, or standalone rules
- SQLite schemas/pragmas/filenames, Project Library and task/scenario/diagnostic formats, version-1 migration behavior, file permissions, atomicity, ordering, timestamps, or user-data locations
- environment names/defaults/ranges/secret classification, native-dialog behavior, Electron security/navigation flags, app identity, icons, entitlements, release targets, signing/notarization/publishing configuration, and Git history/index
- Gate-00 and Gate-01/02 evidence, historical compatibility facts, or user data
- Design System domain neutrality, state-slice ownership, Worker ownership, or performance/accessibility thresholds

Legacy code is protected from deletion until the production cutover, fallback, version-1 migration, package inspection, and complete E2E suite pass. After that point, deletion is allowed only through the path/symbol-exact Continuous Cleanup Manifest described below.

## Required Changes / Workstreams

### Workstream 1 — Design System and Static AppShell (historical IP-03)

1. Define semantic color, typography, spacing, radius (`6/8/12/16/20px`), shadow, material, motion (`120/180/240ms`), z-index, focus, and layout tokens. Light/dark themes share semantic names. Feature code may not consume raw brand colors.
2. Implement domain-neutral primitives (`Surface`, `Stack`, `Text`, `Icon`, `Separator`), controls (`Button`, `IconButton`, `Input`, `Textarea`, `Select`, `Checkbox`, `SegmentedControl`), feedback (`Badge`, `StatusIndicator`, `Spinner`, `Progress`, `Toast`, `InlineError`, `EmptyState`), overlays (`Dialog`, `Popover`, `Tooltip`, `ContextMenu`), and layout (`AppShell`, `Sidebar`, `Toolbar`, `Panel`, `SplitPane`).
3. Use CSS Modules and semantic tokens. Permit only subtle surface gradients; prohibit feature-local control replicas, arbitrary gradients/shadows, or business props such as `recognitionRunning`.
4. Implement keyboard navigation, visible focus, ARIA relationships, overlay focus trap/restore, safe Escape dismissal, portal layering, disabled/loading semantics, and reduced motion.
5. Build Storybook coverage for normal, hover, focus, active, disabled, loading, empty, error, long text, compact density, light, dark, and reduced-motion states.
6. Compose a static AppShell before live features. It performs no backend call or business workflow until the corresponding feature is integrated.
7. Stabilize token and primitive APIs through focused tests and an ADR. Later workstreams may repair or extend them inside this package, but every change must remain domain-neutral and be recorded; no artificial freeze or Sol wait occurs.

Checkpoint: typecheck, Design System/component tests, Storybook build, keyboard/a11y checks, bundle measurement, and non-baseline static-shell visual review. Final frozen visual evidence is created only after full UI integration.

### Workstream 2 — Project Library and Settings (historical IP-04)

1. Implement explicit `projects`, `workspace`, `project-settings`, and `global-settings` route state without a routing dependency.
2. Create `project` and `ui` Zustand slices. Library/project authoritative projections belong to `project`; modal/navigation/notification state belongs to `ui`; form drafts remain local.
3. Migrate Project Library list, active/archive states, create/open/archive/restore, import/export, location change, busy/error states, and default-project restrictions through Shared Contract v1.
4. Migrate Global Settings for provider-key readiness and OCR check/path/save/skip without key readback or persisted drafts. OCR validation must complete before persistence; a failed check must not save.
5. Migrate Project Settings for name/description, provider/model, accuracy, scenario, prompt, Resolve field formats, Comments markers, defaults, normalization, and validation.
6. Guard stale async responses, serialize mutations, prevent duplicate reads/writes, and ensure only one Renderer mode writes a Library.
7. Use only Design System controls and cover empty/loading/error/disabled/focus/archived/busy states.

Checkpoint: page/store/route tests, isolated temporary-Library Electron smoke, provider-key redaction, 500-project responsiveness, visual/a11y states, full compatibility subset.

### Workstream 3 — Slate Input and Preparation (historical IP-05A)

1. Migrate JPEG/PNG/WebP/PDF validation, selection, drag/drop, removal/replacement, thumbnails/pages, grouped multi-page preparation, page counts, filenames, progress, and recoverable errors.
2. Create a `slate` slice separating persisted inputs/results from ephemeral drag, preview, progress, error, object URL, and Worker lifecycle state.
3. Preserve compression profiles, request-size safety ratio, fast/precise views, direct-PDF rules, page order, crop/detail segmentation, filenames, and page counts.
4. Use pdf.js Worker and a typed preparation Worker for heavy work. Any unavoidable canvas work uses async `toBlob`, bounded batches, explicit yielding, and measured proof of no Renderer task over 50 ms.
5. Implement operation-token cleanup for supersession, unmount, object URLs, Workers, and PDF documents/pages. This does not add public recognition cancellation.
6. Differentially compare ported behavior with the legacy modules and avoid running two implementations in one workflow.

Checkpoint: differential fixtures, component and Worker lifecycle tests, long-task/progress measurements, resource-count cleanup, visual states.

### Workstream 4 — Recognition Workflow (historical IP-05B)

1. Migrate Recognition Settings, invocation, progress, results, editable-row handoff, warnings, OCR summaries, diagnostics, and errors using Project defaults and prepared Slate data.
2. Create a dedicated `recognition` slice for operation/project identity, phase, monotonic capped progress, page counters, result/error, and running state; use a narrow high-frequency selector.
3. Subscribe immediately before invocation and always unsubscribe on success, failure, supersession, route/project change, and unmount. Ignore late progress/results by operation and project identity.
4. Preserve serialization, providers/models/prompts/scenarios/accuracy, single/multi-page/PDF behavior, high-accuracy audit/review, order, normalization, warnings, OCR, diagnostics, and task creation timing.
5. Preserve the absence of a public cancel API. UI cleanup must not claim the Main/provider operation was canceled.
6. Present AppError faithfully, including retryable state, 429 busy, readable 504 exhaustion, provider errors, optional/required OCR failures, and page-level warnings/errors.

Checkpoint: recognition golden/differential tests, lifecycle/listener count, stale response and route-switch tests, rerender profile, all visual states.

### Workstream 5 — Metadata and Tasks (historical IP-05C)

1. Migrate Main-owned directory selection/scanning, expected-key coverage, canonical metadata, warnings/missing keys, scan depth, source identity, replace/clear, and stale-scan handling.
2. Keep `metadata` limited to canonical scan results and lifecycle. Do not duplicate recognition records, CSV tables, or task snapshots.
3. Migrate project-scoped task list/new/load/switch/delete, save status/retry, immutable autosave snapshots, serialized in-flight save, pending-save navigation behavior, and restoration.
4. Keep `task` authoritative projections separate from ephemeral selection/save state. SQLite/Main remains authoritative; Zustand is not persistence.
5. Preserve ordering, >50 retention, project isolation, archive rules, IDs/timestamps, latest defaults, JSON snapshots, scenarios/diagnostics, CSV preview fields, autosave debounce/serialization/retry, and write leases.
6. Flush or surface pending saves on switch, invalidate stale requests, clear feature-local ephemeral state, and restore domains through explicit actions rather than one mega-hydrate mutation.
7. Keep CSV computation out of Renderer while later CSV work is incomplete.

Checkpoint: metadata/task/store tests, supported/unsupported metadata sources, Kinefinity/canonical key and current Chinese/full-width normalization, missing directories, scan depth, warnings, file-backed copied version-1 Library tests, autosave concurrency, 1,000-task responsiveness, restoration visuals, and persistence compatibility.

### Workstream 6 — Typed CSV Core and Worker (historical IP-06A)

1. Define a versioned discriminated Worker protocol for decode metadata, prime/clear retained table, merge, normalize, standalone build, encode/export, task errors, and infrastructure errors; correlate every request by ID.
2. Port algorithms without semantic cleanup and differentially compare all existing and Gate-00 fixtures, including exact bytes.
3. Keep the decoded table owned by one long-lived Worker. Renderer holds orchestration, status, sparse edits, and necessary view projections, not a duplicate computation engine.
4. Transfer exact `ArrayBuffer` ranges, including typed-array subviews, without number arrays, JSON binary, adjacent bytes, or avoidable full-buffer copies.
5. Implement task-error classification, infrastructure failure, pending rejection, clear, termination, supersession, unmount cleanup, and ignored late replies.
6. Resolve the legacy Renderer-fallback conflict in the target direction already authorized here: modern mode must use Worker-owned recovery/recreation and must never execute CSV algorithms in Renderer. Preserve user-visible success/failure and healthy task-error behavior. Record the decision and measurements in the Decision Queue/ADR. Any required Main ownership, Shared Contract change, or user-visible semantic change remains a blocking Stop Condition.
7. Expose a stable internal Worker service to the table/export workstreams.

Checkpoint: byte goldens, old/new differential suite, transfer/lifecycle/failure tests, memory and 10,000-row timing, zero Renderer CSV long tasks.

### Workstream 7 — Virtual Table, Editing, and Export (historical IP-06B/C)

1. Render stable original-order columns and rows with TanStack Table/Virtual, stable memoized columns, and row IDs independent of view index.
2. Present matched, edited, missing, conflicting/anomaly, warning, and untouched states without recomputing CSV semantics in Renderer.
3. Store sparse `row:column` edits plus minimal selection/sort/filter/viewport UI state. Do not duplicate full derived tables or persist views.
4. Implement keyboard navigation, focus retention across virtualization, cell entry/commit/cancel, screen-reader labels, sticky headers, empty/loading/error states, and compact density.
5. Localize row/cell updates; one edit must not rerender all visible rows or recreate columns.
6. Complete Resolve/slate CSV load, direct and recognition-result merge, metadata backfill, summaries, clear/replace, sparse editing, standalone export, encode, and native save entirely through the typed Worker.
7. Preserve encoding/BOM/newline/delimiter, original columns/rows/order, quotes, multi-scene, match/conflict/missing, width/non-truncation, Comments allowlist, backfill, sparse edits, unmatched rows, standalone behavior, exact bytes, default filename, cancel result, task snapshot fields, and Project ownership.
8. Send exact binary through `slateSync.files.save`, guard overlapping Worker exports/dialogs, and distinguish task errors from infrastructure failures.

Checkpoint: <100 DOM rows for 10,000 rows, scroll/focus/profiler tests, exact input-to-saved-output bytes, task restore, dialog/overlap tests, 55+ FPS and no repeated >50 ms Renderer task.

### Workstream 8 — Integration, Production Cutover, E2E, and Unified Visual Baseline (historical IP-07)

1. Integrate the seven slices (`project`, `task`, `slate`, `recognition`, `metadata`, `export`, `ui`) through explicit coordination actions without cross-slice mutation, duplicate truth, or a mega-store.
2. Move Main lifecycle/composition to the typed target entry while reusing Main-owned services. Test injection is limited to a separate test composition entry and is never a production flag/global.
3. Make modern Renderer the development/packaged default. Retain a bounded, observable legacy rollback for missing/corrupt assets or an internal recovery switch. Exactly one Renderer boots and no double writes occur.
4. Keep typed Preload as the sole gateway and package compiled Main, CommonJS Preload, Renderer, Workers, legacy fallback, services, native SQLite, pdf.js, OCR resources, config, icons, and entitlements.
5. Complete Storybook for feature and cross-feature empty/loading/error/disabled/busy/restored states.
6. Add Playwright Electron E2E with isolated temporary `userData` and copied/synthetic Project Libraries, offline provider/dialog fixtures, no production hook, no network, no real credentials, and no fixed sleeps.
7. Cover first launch, Library/project/settings, image/PDF preparation, recognition lifecycle, metadata, tasks/autosave/restore/switch, Resolve/slate CSV, 10,000-row editing, export bytes, archive/restore, relaunch, version-1 data, and rollback.
8. Add additive CI validation for typecheck, Node/baseline tests, modern unit/component tests, Storybook, bounded E2E, package inspection, and smoke without altering release semantics.
9. Establish and verify visual evidence only after the UI is integrated. Include the ten Gate-00-equivalent states plus modern light/dark/compact/error states at 1440×900 and 960×600, deterministic state readiness, stable reruns/hashes, accessibility, keyboard, focus, and reduced motion. Missing visual evidence does not block earlier non-UI work, but it blocks completion and Final Review readiness.
10. Measure cold start, first usable Library, project/task switching, preparation/progress responsiveness, rerenders, binary copies, leaks, and package contents.

Checkpoint: complete unit/component/baseline suite, Storybook, Playwright runs, copied version-1 migration, production/fallback smoke, unified visual/a11y review, performance/memory, unsigned directory package.

### Workstream 9 — Manifest-Limited Cleanup (historical IP-08)

No intermediate Sol Gate is required. Safety moves into a path/symbol-exact manifest and evidence checkpoint:

1. Generate `.codex/refactor/CONTINUOUS_CLEANUP_MANIFEST.md` from the current integrated state. Enumerate every file, symbol, dependency, script, route, IPC channel, style, asset, test, adapter, fallback item, generated-output path, and comment proposed for deletion or replacement. Category or wildcard authorization is invalid.
2. Append one `IP-03-08-CONTINUOUS-CLEANUP-*` Decision Queue entry that links the exact manifest and records the Owner-authorized manifest-limited cleanup rule. It is non-blocking only while every target satisfies this package; ambiguity, live use, compatibility impact, or scope expansion makes it blocking.
3. For every item, record pre-delete references, package/runtime/migration relevance, replacement, retained coverage, exact action, and rollback/compatibility effect.
4. Verify zero required production/test/package/version-1/user-data dependency before deletion. Preserve migration readers, version-1 support, compatibility fixtures, and anything still used by rollback or packaging even when named `legacy`.
5. Remove only manifest-listed legacy Renderer/bootstrap code, temporary adapters, dead IPC, unused dependencies/scripts/styles/assets/tests, generated paths, and stale comments. A test may be removed only after stricter modern replacement coverage exists. Rebuild the lockfile only through exact removals; do not upgrade opportunistically.
6. Remove the legacy rollback only when the same continuous run has packaged recovery evidence and the manifest proves it is safe. Otherwise retain it and report accepted debt for Sol Final Review.
7. Run orphan detection for files, exports, IPC, CSS/tokens, dependencies, scripts, and package resources. A newly discovered orphan not in the manifest is recorded and left in place until the manifest is updated and revalidated.
8. Update architecture/compatibility/migration documentation and comments to the actual final state.
9. Rerun every final validation after cleanup. Any live reference, ambiguity, migration/data dependency, coverage gap, unexpected lockfile churn, or compatibility/security/performance regression is a Stop Condition; restore or retain the item rather than forcing deletion.

Checkpoint: manifest scope verifier, pre/post reference evidence, clean install, all tests/E2E/package/visual/performance/security checks, orphan audit, and zero out-of-manifest cleanup changes.

## Existing Behavior That Must Remain

At minimum, preserve every behavior in the Compatibility Contract, including:

- recognition normalization, formatting, page order, inheritance/reconciliation, high-accuracy stages, progress, timeout/retry/AbortError, concurrency, provider/OCR routing, errors, leases, and no public cancellation
- recognition defaults and ranges: request timeout 180000 ms clamped to 30000–3600000, retries default 1 clamped to 0–3, page concurrency default 2 with range 1–6, and recognition-process concurrency default 1 with range 1–16
- all 27 migrated operations, Result/AppError mapping, legacy-compatible transition behavior while fallback exists, listener cleanup, exact binary ranges, native dialogs, and Electron security/navigation
- CSV decoding/encoding, original data preservation, matching/conflicts/missing behavior, field widths, Comments, sparse edits, standalone export, worker retained state, exact bytes, and task snapshots
- SQLite WAL/foreign keys/busy timeout, schema and filenames, atomic/private storage, JSON snapshots, migration semantics, task defaults/order/timestamps, Library layout/versions/default project/location/import/export/relaunch
- environment and secret ownership, public redaction, machine/project setting ownership, release resources, and unsigned refactor-build policy
- existing user Libraries/tasks/settings opening without rewrite or loss; copied migration fixtures must leave their source unchanged

## Public Interfaces and State Ownership

- `window.slateSync` and frozen Shared Contract v1 remain the only Renderer gateway; no `electronAPI`, raw channel, generic invoke, filesystem, SQLite, secret, Electron object, or public test hook.
- `Result<T>` / `AppError` and idempotent progress unsubscribe remain unchanged.
- State slices remain `project`, `task`, `slate`, `recognition`, `metadata`, `export`, and `ui`. Persisted and ephemeral state are separated; derived state is not duplicated.
- Worker protocols are typed/versioned internal interfaces. Worker owns CSV computation; Renderer owns light orchestration and view/edit state.
- Design System APIs are domain-neutral. Feature code composes them and does not fork primitive systems.
- No public interface, persistence format, CSV meaning, recognition behavior, or ownership boundary may be invented or changed silently. A necessary change is a blocking Decision Queue item.

## Acceptance Tests / Final Acceptance Matrix

Use actual scripts from the approved repository. At minimum retain command, exit code, duration, environment, and evidence path for:

0. `node .codex/refactor/verify-current-state.mjs` before implementation and
   again before handoff; package version/hash/authority drift is a Stop
   Condition until reconciled by Sol
1. clean `npm ci`
2. `npm run check`
3. `npm run typecheck`
4. complete Node/baseline suite
5. complete modern Vitest/component suite
6. aggregate `npm test`
7. modern/Main/Preload/Renderer/Storybook builds
8. Electron development, production, fallback, and packaged smoke
9. Playwright Electron E2E, including two fresh runs and one copied version-1 Library run
10. `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`
11. Gate-00 recognition/CSV/persistence/contracts/visual compatibility tests
12. exact CSV differential/byte suite and deliberate one-byte mutation failure
13. Worker transfer/memory/lifecycle/failure suite
14. 10,000-row virtualization, rerender, keyboard, scroll, and export performance suite
15. unified deterministic visual capture, stable rerun/hash, human visual review, keyboard, ARIA, focus, contrast, and reduced motion
16. clean package-content/security/navigation/secret/native-resource inspection
17. migration/source-integrity checks for copied version-1 Library and task data
18. Cleanup Manifest verifier, orphan audit, lockfile integrity, `git diff --check`, and package scope verifier

No skipped/todo/only test, auto-accepted golden, placeholder screenshot, production-only test hook, fixed sleep, real secret, or live user data is acceptable evidence.

## Performance Constraints

- Visible feedback within one animation frame.
- The tree-shaken static Design System/AppShell remains below 250 KiB gzip excluding React; opening an overlay adds no synchronous task over 16 ms; reduced motion disables animation; no idle timer or polling is introduced.
- No CSV Renderer compute task over 50 ms; PDF preparation yields between bounded work.
- Preparation progress performs no more than 10 UI commits per second while remaining useful; replacing/unmounting returns Worker/object-URL/PDF-resource counts to baseline.
- Fewer than 100 DOM data rows for a 10,000-row table and 55+ FPS on the baseline machine.
- Sparse edit is O(1) store work plus bounded visible-row rendering; no full-table clone for one edit.
- No unnecessary `ArrayBuffer` copy, avoidable second full export buffer, or JSON/number-array binary. Worker peak additional memory remains below 1.25× payload plus documented table representation, and 10,000-row wall time remains within 10% of the legacy Worker.
- Progress updates are selector-scoped and capped to a useful cadence; no AppShell-wide high-frequency rerender.
- Project/task selection remains responsive for 500 projects / 1,000 task summaries with no uncontrolled request fan-out.
- Autosave has at most one active write and one latest pending immutable snapshot; metadata scanning remains Main-owned without avoidable duplicate large-array cloning.
- Production cold start, first usable Project Library, and project/task switching remain within 15% of the measured legacy baseline.
- No leaked BrowserWindow, Worker, listener, object URL, PDF resource, timer, database connection, or retained callback after close/switch/unmount.
- Cleanup does not regress Final pre-cleanup metrics; package size should decrease or remain within 1% with explained build metadata, and cold start/memory within 5% measurement noise.

## Stop Conditions

Stop the affected work and the continuous run when continuing would prejudge or compound any of these:

1. Architecture Invariant, Shared Contract v1, state ownership, Main/Preload/Renderer/Worker ownership, or Design System boundary must change beyond the explicit Worker-fallback direction authorized here.
2. Recognition/provider/OCR, timeout/retry/concurrency/cancellation, CSV semantics/bytes, persistence/schema/migration, Project Library/task format, environment, native-dialog, security, or release behavior must change.
3. Compatibility behavior or a DTO cannot be proven from code/tests/fixtures, or a golden must be weakened/auto-updated.
4. Data loss/corruption, double write, duplicate source of truth, unsafe pending-save transition, live user-data dependency, secret exposure, or migration ambiguity appears.
5. Heavy work cannot leave Renderer, binary transfer requires prohibited copies/serialization, or performance/accessibility thresholds cannot be met safely.
6. A dependency outside the authorized list, a public test hook, real credential/network dependency, fixed-sleep E2E, or production capture hook is required.
7. Worker fallback needs Main ownership, Shared Contract change, or changed user-visible semantics.
8. Production cutover cannot preserve a single Renderer, bounded recovery, package resources, version-1 data, or exact behavior.
9. A cleanup target has a live/ambiguous reference, is absent from the exact manifest, affects migration/fallback/data, requires test weakening, or causes unexpected lockfile churn.
10. Any final validation failure remains unexplained or cannot be corrected within the package without expanding authority.

For an in-scope implementation bug with an understood safe fix, repair and rerun instead of escalating. For a true Stop Condition, append a structured `IP-03-08-CONTINUOUS-*` Decision Queue entry, preserve evidence, report `BLOCKED`, and do not improvise a new contract.

## Deliverables

- Complete target Main/Preload/Shared/React Renderer architecture and all seven domain slices
- Domain-neutral Design System, Storybook catalog, feature UI, typed Workers, virtualized table, exact CSV workflows, production cutover, bounded fallback, and E2E
- Unified post-UI visual baseline and accessibility/keyboard evidence
- Path/symbol-exact `.codex/refactor/CONTINUOUS_CLEANUP_MANIFEST.md` and manifest-limited cleanup evidence
- Updated ADRs, Compatibility Contract transition/final-state notes, Migration Matrix, architecture/ownership/lifecycle comments, and evidence ledger
- Complete test/build/package/performance/memory/migration/security/compatibility evidence
- One Continuous Completion Report with `ARCHITECTURE DEVIATIONS: NONE` or a blocking Decision Queue entry

## Continuous Completion Report

```text
PACKAGE: IP-03-08-CONTINUOUS
STATUS: READY FOR FINAL REVIEW | BLOCKED
START HEAD:
START STATUS / DIFF INVENTORY:
GATE-01-02 BASELINE:

WORKSTREAMS COMPLETED:
- Design System / AppShell
- Projects / Settings
- Slate Preparation
- Recognition
- Metadata / Tasks
- CSV Worker
- Virtual Table / Export
- Integration / Cutover / E2E / Visual
- Cleanup

IMPLEMENTED:
CHANGED FILES:
COMMENTS UPDATED:
TESTS ADDED OR UPDATED:
CHECKPOINT LEDGER:
FINAL VALIDATION:
PERFORMANCE / MEMORY:
VISUAL / ACCESSIBILITY:
MIGRATION / DATA SAFETY:
COMPATIBILITY:
CLEANUP MANIFEST:
DECISION QUEUE:
ARCHITECTURE DEVIATIONS: NONE
KNOWN LIMITATIONS:
GIT COMMIT PERFORMED: NO
READY FOR SOL FINAL REVIEW: YES | NO
```

## Sol Final Review

Sol reviews the complete diff from the approved Gate-01/02 baseline, every checkpoint and final-validation record, Architecture Invariants, Compatibility Contract, Decision Queue, the Cleanup Manifest and deletions, migration evidence, visual/accessibility evidence, performance/memory, package contents, comments, and tests. Sol must independently inspect and rerun risk-proportionate validation rather than trust the Completion Report.

Write the verdict to `.codex/refactor/reviews/FINAL-IP-03-08.md`:

- `APPROVED`: the complete IP-03-08 refactor is accepted.
- `CHANGES REQUIRED`: list exact findings and produce a bounded continuous Correction Package; do not silently authorize unrelated work.

There are no intermediate IP-03 through IP-08 Review Gates. Only this Final Review can declare the post-IP-02 refactor complete.
