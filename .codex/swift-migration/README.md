# SlateSync Swift migration authority

Updated: 2026-09-03
Current phase: **SM-01 review ready; formal admission pending; SM-02 not started**
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

The implementation is `REVIEW_READY`, not formally `COMPLETE`: it still needs a
clean dedicated review commit, a formal `phase_gate.sh` PASS, and Owner approval.

SM-02 and every later package remain unstarted. In particular, the Electron and
Windows-era files are still retained as migration evidence until the applicable
phase is explicitly authorized.
