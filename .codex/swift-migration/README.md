# SlateSync Swift migration authority

Updated: 2026-09-04
Current phase: **SM-03 COMPLETE; SM-04 implementation in progress**
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

The SM-01, SM-02 and SM-03 implementations are formally `COMPLETE` in
`CURRENT_STATE.json`. SM-04 is the active implementation package. Review of its
first dedicated commit found actor-reentrancy, shutdown/activation and Gate
classification defects; fixes and regressions form the Owner-authorized
dedicated review-fix change set. Governance cannot advance until that exact
commit has a clean `phase_gate.sh` evidence report and the Repository Owner
explicitly approves it.

SM-04 now includes the complete v1 portable transfer boundary: staged Project
and Library exports use SQLite online backups, imported projects receive fresh
ownership across database rows and snapshots, unsafe external trees are
rejected, and active-Library changes persist the selected path and drain all
outgoing connections before the app-level restart. The native App composition
root consumes that path lazily on relaunch and retains Electron's known-default
migration/conflict behavior without rewriting portable selections. These changes remain
subject to the same clean Gate and Owner-approval lifecycle.

SM-04 review hardening makes Library/startup/project-store bootstrap
single-flight, serializes project terminal operations and runtime close,
drains snapshot writes before Library rename, admits only one concurrent
activation, makes duplicate Scenario import idempotent, fails closed on
transfer traversal errors, and correctly distinguishes UI automation setup
blocks from product test failures.

Electron, React, Node and cross-platform-era files remain retained as migration
evidence until SM-09; SM-02 changes only their current macOS product entrypoints.
