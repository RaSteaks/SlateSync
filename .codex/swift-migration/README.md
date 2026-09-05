# SlateSync Swift migration authority

Updated: 2026-09-05
Current phase: **SM-06 COMPLETE; SM-07 implementation IN_PROGRESS**
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

SM-01 through SM-06 are formally complete. `CURRENT_STATE.json` records
SM-06 COMPLETE at the approved review commit
`3ba200cafad758b10ad51c08eace5024bcffa90e`. SM-04 supplies the v1
Library/SQLite ownership and portable transfer boundary, SM-05 supplies
byte-compatible CSV, metadata and Scenario v1 behavior, and SM-06 supplies the
native media/OCR handoff.

SM-06 implements native image/PDF preparation, full/detail JPEG views,
immutable request compression, built-in Vision and the explicit legacy helper
adapter, supervised Paddle processes, OCR policy/cache/evidence, and a local
Workflow handoff. It retains the shared Python runner in App resources and
verifies real inference offline with explicitly supplied runtime/model fixtures.
SM-07 implementation now supplies the secret-safe Provider registry,
URLSession transport, discovery/probes, exact prompts/schemas, response
normalization, bounded page/high-accuracy pipeline, and OCR-first recognition
coordinator with progress/cancel/persistence lifetime. Workspace UI and
distribution remain SM-08 and SM-09 responsibilities. Scenario v1 remains
unchanged; legacy TakeStatus strings cross one SM-07 adapter.

SM-06 implementation and formal evidence are recorded in `reviews/SM-06.md`.
The separately authorized SM-07 code construction is complete and its latest
dirty diagnostic Gate passed every technical check at
`.codex/gate-results/SM-07/20260905T122916Z-d65a6063fe80/`. This remains an
implementation result, not phase approval: `CURRENT_STATE.json` deliberately
stays at the formally approved SM-06 COMPLETE boundary until SM-07 has a
dedicated review commit, exact-SHA clean Gate evidence, review report, and
explicit Owner approval.

Electron, React, Node and cross-platform-era files remain retained as migration
evidence until SM-09; SM-02 changes only their current macOS product entrypoints.
