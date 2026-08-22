# PACKAGE: IP-01 / C01 — Local Completion Evidence

EVIDENCE STATUS: **HISTORICAL, ACCEPTED BY GATE 01-02, NON-EXECUTABLE**.
“Ready for re-review” below records the Implementer handoff at that time; the
current Gate verdict is `APPROVED` and the active package is
`IP-03-08-CONTINUOUS` version `2026-08-21.2`.

Status: **COMPLETED — READY FOR GATE 01-02 RE-REVIEW**

Architecture invariant deviations: **NONE**

## Implemented boundary

- Main, Shared, Preload type declarations, and Renderer declarations have
  deterministic non-overlapping outputs below `out/**`; incremental metadata
  is below `out/.tsbuildinfo/**`.
- Ordinary and packaged startup remain legacy. The development-only modern
  selector is opt-in; missing selector output and failed modern navigation
  both fall back to legacy in the same production composition root.
- BrowserWindow loads the one compiled typed Preload directly. This preserves
  `sandbox: true`; the sandbox cannot require a second repository-local module.
- Named Node/Electron rebuild hooks prepare the ABI required by each runner.
  Electron smoke restores Node ABI in its outer `finally` on success/failure.
- CI and release validate strict typecheck plus modern build without changing
  identity, targets, signing, notarization, publishing, triggers, or secrets.

## Validation

| Command/evidence | Result |
| --- | --- |
| `npm ci` | PASS; 403 packages from the lockfile |
| `npm run check` | PASS |
| `npm run typecheck` | PASS |
| `npm run test:node` | PASS; 229/229 |
| `npm run test:modern` | PASS; 2 files / 6 tests |
| `npm test` | PASS; Node 229/229 + modern 6/6 |
| `npm run build:modern` | PASS |
| `npm run test:electron:smoke` | PASS; production default/modern/missing/load-failure paths |
| `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir` | PASS; unsigned arm64 app |
| `npm run test:electron:package-smoke` | PASS; packaged executable startup |
| IP-01 exact scope verifier | PASS; no prefix exemptions |

## Performance and package evidence

- `out/renderer/assets/index-BNxC2gzE.js` is 190,906 bytes, below 500 KiB.
- Five production runs per mode use a temporary profile/library and wait for
  mode-specific meaningful UI plus fonts and two animation frames. Median
  legacy readiness is 169.4 ms; modern is 164.5 ms (97.1% of legacy).
- Production smoke proves one Renderer, exact roots, denied navigation/window
  creation, six-domain `slateSync`, no `electronAPI`/Node globals, native
  SQLite, pdf.js, missing/corrupt modern fallback, and no provider network.
- Packaged smoke proves modern selection is refused in packaged mode and the
  unsigned app contains/uses the typed Preload, SQLite and pdf.js resources.

Evidence: `performance.json`, `production-smoke.json`,
`packaged-smoke.json`, `package-content.txt`, and `changed-paths.json`.
