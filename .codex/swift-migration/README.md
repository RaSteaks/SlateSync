# SlateSync Swift migration authority

Updated: 2026-09-05
Current phase: **SM-05 COMPLETE; SM-06 implementation in progress**
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
- A phase advances only through the lifecycle and Owner approval rules in
  `PHASE_GATES.md`; a dirty diagnostic run can never approve a phase.

## Current implementation boundary

The SM-01 implementation provides the five SwiftPM libraries and Xcode App/Unit/UI Test
targets, shared Scheme and Test Plan, native WindowGroup and Settings shells,
the Icon Composer app icon, and the deterministic build-and-run script. Debug
uses the active host architecture with `-Onone`; Release and Archive contain
both arm64 and x86_64 and declare macOS 15.0 as the minimum system.

SM-01 through SM-05 are formally complete. `CURRENT_STATE.json` records
SM-05 COMPLETE at the approved review commit
`7c36f642632401ac21ff97316f1f3a9c1e8e6530`; SM-06 is the separately authorized
implementation package. SM-04 supplies the v1 Library/SQLite ownership and
portable transfer boundary. SM-05 supplies byte-compatible CSV, metadata and
Scenario v1 behavior.

SM-06 implements native image/PDF preparation, full/detail JPEG views,
immutable request compression, built-in Vision and the explicit legacy helper
adapter, supervised Paddle processes, OCR policy/cache/evidence, and a local
Workflow handoff. It retains the shared Python runner in App resources and
verifies real inference offline with explicitly supplied runtime/model fixtures.
Provider transport/orchestration, the workspace UI and distribution remain
SM-07 through SM-09 responsibilities. Scenario v1 is unchanged; legacy
TakeStatus string conversion belongs to the SM-07 adapter.

Implementation and diagnostic evidence are recorded in `reviews/SM-06.md`.
SM-06 remains IN_PROGRESS until a dedicated review commit, a clean Gate on
that exact SHA and explicit Owner approval complete the admission workflow.

Electron, React, Node and cross-platform-era files remain retained as migration
evidence until SM-09; SM-02 changes only their current macOS product entrypoints.
