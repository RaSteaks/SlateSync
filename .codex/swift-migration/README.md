# SlateSync Swift migration authority

Updated: 2026-09-10
Current phase: **SM-09 technical Gate PASS; Owner approval pending within local ad-hoc scope**
Development baseline: **`swift-rewrite`**
Main branch architecture: **Electron; Swift merge is prohibited before an explicit architecture decision**
Target: **native macOS 15.0+, arm64 + x86_64**

This directory is the current authority for replacing the Electron application
with a native Swift application. `.codex/refactor/` remains immutable historical
evidence for the compatibility behaviors that the Swift implementation must
preserve.

## Authority order

1. `COMPATIBILITY_CONTRACT.md`
2. `ARCHITECTURE.md`
3. `MASTER_PLAN.md`
4. the active package under `packages/`
5. `PHASE_GATES.md`
6. `MIGRATION_MATRIX.md` and `DECISION_QUEUE.md`
7. historical Electron refactor material

## Operating rules

- All automated persistence and UI tests use explicit temporary Application
  Support and Project Library roots. The user's default Library is out of scope.
- Swift code changes include comments for non-obvious ownership, concurrency,
  compatibility and recovery logic.
- Windows support is terminated. New build, CI and release work is macOS-only.
- `main` remains the Electron architecture branch. Current Swift development
  branches start from `swift-rewrite` and target `swift-rewrite`.
- Before an explicit Owner/project decision makes Swift the primary architecture,
  no `swift-rewrite` branch may merge into `main`.
- A phase advances only through the lifecycle and Owner approval rules in
  `PHASE_GATES.md`; a dirty diagnostic run can never approve a phase.

## Current implementation boundary

The SM-01 implementation provides the five SwiftPM libraries and Xcode App/Unit/UI Test
targets, shared Scheme and Test Plan, native WindowGroup and Settings shells,
the Icon Composer app icon, and the deterministic build-and-run script. Debug
uses the active host architecture with `-Onone`; Release and Archive contain
both arm64 and x86_64 and declare macOS 15.0 as the minimum system.

SM-01 through SM-09 have complete native implementation and technical Gate
coverage within the local ad-hoc scope. `CURRENT_STATE.json` records SM-09
PASS while the current repair commit awaits explicit Owner approval; the native
implementation is developed from `swift-rewrite`, while `main` remains the
Electron baseline.
SM-04 supplies the v1 Library/SQLite ownership and portable transfer boundary,
SM-05 supplies byte-compatible CSV, metadata and Scenario v1 behavior, and
SM-06 supplies the native media/OCR handoff.

SM-06 implements native image/PDF preparation, full/detail JPEG views,
immutable request compression, built-in Vision and the explicit legacy helper
adapter, supervised Paddle processes, OCR policy/cache/evidence, and a local
Workflow handoff. SM-07 supplies the secret-safe Provider registry, URLSession
transport, discovery/probes, exact prompts/schemas, response normalization,
bounded page/high-accuracy pipeline, and OCR-first recognition coordinator.
SM-08 and SM-09 complete the workspace UI, lifecycle, native packaging,
compatibility evidence and Electron runtime removal from the active Swift tree.
Scenario v1 remains unchanged; legacy TakeStatus strings cross one SM-07 adapter.

SM-09 implementation and formal evidence are recorded in `reviews/SM-09.md`.
The approved completion scope is local native delivery only; Developer ID,
notarization, public distribution and GitHub Release are not part of the current
target. GitHub source pushes and native CI validation are in scope, while
`swift-rewrite` remains the only baseline for new Swift development.

Electron, React, Node and cross-platform-era files remain on `main` and in
protected historical evidence; they are not the active runtime of the native
`swift-rewrite` tree.
