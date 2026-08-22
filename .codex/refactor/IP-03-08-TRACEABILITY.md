# IP-03-08 continuous-package traceability

Status: **CURRENT COVERAGE MAP FOR PACKAGE VERSION 2026-08-21.2**  
Source: `packages/IP-01——IP-08.md` (historical, non-executable)  
Target: `packages/IP-03-08-CONTINUOUS.md` (sole executable package)

This map proves that removing historical construction boundaries did not remove
their effective requirements. A historical prerequisite, local freeze, Sol
handoff, standalone Gate, or stage wait is intentionally not carried forward;
the associated technical, compatibility, test, performance, migration,
accessibility, visual, and cleanup requirement is.

| Historical source | Active workstream | Carried requirement families | Active verification |
| --- | --- | --- | --- |
| IP-03 | Workstream 1 — Design System and Static AppShell | semantic foundations; domain-neutral primitives/controls/feedback/overlays/layout; CSS Modules; themes; focus/keyboard/ARIA; reduced motion; Storybook; static shell | component/a11y/Storybook/build/bundle/static visual checkpoint; final visual/accessibility matrix |
| IP-04 | Workstream 2 — Project Library and Settings | explicit routes; project/ui slices; Library lifecycle; Global/Project Settings; provider-key redaction; OCR validate-before-save; stale/mutation guards; Design System reuse | route/store/page tests; temporary Library Electron smoke; 500-project response; settings visuals/a11y; compatibility subset |
| IP-05A | Workstream 3 — Slate Input and Preparation | file validation; PDF/page grouping; previews; compression and request sizing; pdf.js and typed preparation Worker; yielding; operation/resource cleanup; old/new differential parity | differential fixtures; lifecycle/resource tests; progress/long-task metrics; prepared-state visuals |
| IP-05B | Workstream 4 — Recognition Workflow | dedicated recognition state; immediate subscribe/finally unsubscribe; stale-operation guards; unchanged providers/prompts/scenarios/accuracy/page order/audit/review/OCR/diagnostics/task timing; no public cancellation | recognition goldens; listener/stale-route tests; error matrix; rerender profile; complete recognition visuals |
| IP-05C | Workstream 5 — Metadata and Tasks | Main-owned scanning; canonical metadata; project-scoped task lifecycle; serialized immutable autosave; SQLite authority; >50 retention; project isolation; version-1 restore/migration; no duplicate CSV computation | metadata/task/store/concurrency tests; copied version-1 Library/source integrity; 1,000-task response; persistence and restore visuals |
| IP-06A | Workstream 6 — Typed CSV Core and Worker | versioned protocol; exact old/new algorithms/bytes; one retained Worker table; exact transferable ranges; task/infrastructure failure lifecycle; Worker-owned recovery with zero Renderer algorithm fallback | byte goldens/mutation failure; differential suite; transfer/lifecycle/failure/memory/10,000-row timing; zero Renderer long tasks |
| IP-06B and IP-06C | Workstream 7 — Virtual Table, Editing, and Export | TanStack virtual table; stable IDs/order; sparse edits; keyboard/focus/a11y; localized rerender; complete merge/backfill/edit/encode/native-save workflow through Worker; exact bytes/default filename/cancel behavior | DOM-row/rerender/scroll/keyboard/edit tests; 10,000-row performance; export bytes; E2E and visual states |
| IP-07 | Workstream 8 — Integration, Production Cutover, E2E, and Unified Visual Baseline | one production Renderer; complete workflows; bounded recovery; fresh/copied-v1 E2E; security/navigation/secrets/package resources; unified deterministic modern visual and accessibility evidence; performance/memory/leak audit | two fresh and one copied-v1 E2E runs; production/package smoke; migration integrity; two-run visual hashes plus human review; performance/security/package inspection |
| IP-08 | Workstream 9 — Manifest-Limited Cleanup | path/symbol-exact manifest; references/replacement/coverage/rollback proof; version-1/fallback protection; exact dependency/script/style/asset/comment cleanup; orphan audit; full post-cleanup rerun | manifest verifier; pre/post references; clean install; all final tests/E2E/package/visual/performance/security; zero out-of-manifest deletion |

## Cross-cutting requirements retained

- The union Allowed Scope and global Protected Scope replace historical
  per-stage boundaries without expanding ownership.
- Architecture Invariants, Compatibility Contract, Shared Contract v1,
  Result/AppError, sole `window.slateSync`, and Worker/Main ownership remain
  binding.
- Recognition, CSV bytes, SQLite/Project Library/task/scenario formats,
  environment, dialogs, security, signing, and user data remain protected.
- Authorized dependencies and exact-version/lockfile rules remain binding.
- Every checkpoint retains focused evidence, but only the complete final matrix
  and one Sol Final Review can approve the refactor.
- Performance, memory, visual, accessibility, migration/source-integrity,
  package, security, cleanup, comment, and no-skipped-test obligations remain.
- A true Stop Condition still enters Decision Queue; a historical IP number
  change never creates a stop or model handoff.

## Intentional governance supersession

The following historical mechanisms are deliberately inert:

- Joint Gate 03-04, Gate 05A-C, Gate 06A, Gate 06B-C, Gate 07, and Gate 08;
- provisional API freezes that required waiting for those Gates;
- separate package admission and Stop-after-package instructions;
- Sol-only pre-cleanup manifest generation;
- standalone IP-08 regeneration after Gate 07.

Their safety outcomes are preserved by continuous checkpoints, the exact
Cleanup Manifest, the final validation matrix, and the one Sol High Final
Review. This document is a coverage map, not a second implementation package.
