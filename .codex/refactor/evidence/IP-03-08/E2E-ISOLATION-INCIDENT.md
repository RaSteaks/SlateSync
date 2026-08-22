# E2E Isolation Stop-Condition Record

Date: 2026-08-21 (Asia/Shanghai)

## Observation

The first Playwright Electron fixture and the first visual-capture fixture
passed `--user-data-dir=<temporary-directory>` but did not seed the persisted
`settings.json` `libraryPath`. On macOS, Electron's `app.getPath("appData")`
remains the OS application-data root while `--user-data-dir` changes the
profile directory. SlateSync's safe default library is derived from
`app.getPath("appData")` when `libraryPath` is empty.

The default library path was confirmed to exist. The affected attempts were:

- `npm run test:e2e` before the isolation fix: two fresh assertions, one
  copied-library assertion, and one integrated CSV Worker assertion;
- `node test-support/e2e/capture-visual-baseline.mjs` before the isolation
  fix: the first capture attempt reached project creation and stopped on a
  selector assertion, and the second reached archive capture and stopped on a
  selector assertion.

These attempts may have opened or written synthetic project records in the
default library. No deletion, direct SQLite mutation, reset, or cleanup was
performed because the user explicitly prohibited operating on an active
Project Library.

## Containment

`test/e2e/electron.spec.ts` and
`test-support/e2e/capture-visual-baseline.mjs` now write a temporary
`settings.json` before Electron launch, with `libraryPath` inside the same
temporary profile. The contained rerun was not started after this discovery.
The Node ABI was restored with `npm run rebuild:native:node`.

## Required decision

Sol/user direction is required before any further Electron, E2E, visual,
packaging, migration, or Project Library command. The default library must be
audited or restored by its owner using an approved, user-visible procedure;
the Implementer must not infer permission to inspect, archive, delete, or
rewrite it.

Status: **BLOCKING STOP CONDITION — POTENTIAL USER-LIBRARY TEST CONTAMINATION**.
