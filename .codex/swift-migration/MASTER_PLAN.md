# SlateSync native Swift master plan

SlateSync is being rewritten in place as a macOS 15 native application. Five
SwiftPM libraries hold reusable application code while `SlateSync.xcodeproj`
owns the app bundle, shared scheme, unit tests, UI tests, Run, Debug, Profile and
Archive workflows.

## Phases

| Phase | Outcome |
| --- | --- |
| SM-00 | Freeze compatibility and establish the new authority documents. |
| SM-01 | Create SwiftPM modules, Xcode app/test targets and runnable shell. |
| SM-02 | Remove Windows claims, build paths and release configuration. |
| SM-03 | Port domain contracts, settings, OSLog and Keychain migration. |
| SM-04 | Port SQLite and Project Library v1 without format churn. |
| SM-05 | Port CSV, metadata scan and scenario profiles with byte goldens. |
| SM-06 | Port PDF/image preparation, Vision OCR and PaddleOCR process bridge. |
| SM-07 | Port provider discovery and recognition orchestration. |
| SM-08 | Complete native project, workspace, settings, logs and help workflows. |
| SM-09 | Run compatibility gates, archive Universal app and remove Electron. |

Each phase is described in `packages/SM-XX.md`. The migration is allowed to
keep the Electron implementation only as reference and differential-test input
until SM-09; it is not a second product direction.

Phase lifecycle, evidence substitution, Owner approval, and the single local/CI
Gate entrypoint are defined in `PHASE_GATES.md`.
