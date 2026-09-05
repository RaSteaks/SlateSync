# Gate-00 visual capture failure evidence

> Repository cleanup note (2026-09-05): this incident summary remains tracked;
> raw successful-run captures and comparison manifests were removed.

CLASSIFICATION: **HISTORICAL FAILED-RUN DIAGNOSTIC — SUPERSEDED BY THE LATER
SUCCESSFUL LEGACY CAPTURE; NOT A CURRENT BLOCKER**.

- Recorded at: `2026-08-19T17:08:20Z`
- Repository: `/Users/rasteaks/Desktop/个人/GitHub/SlateSync`
- Platform: macOS 15.7.3, arm64
- Node: `v24.13.0`
- Electron: `43.3.0`
- Command: `./node_modules/.bin/electron test-support/baseline/capture-visuals.mjs`
- Execution host: the current user's macOS Terminal desktop session
- Result: failed before `app.whenReady()`; no BrowserWindow, PNG, manifest, or
  run-comparison evidence was produced

## Exact terminal output

```text
waiting for Electron app readiness
Visual baseline capture failed: Error: Electron app.whenReady() timed out after 15000ms
    at Timeout.<anonymous> (file:///Users/rasteaks/Desktop/%E4%B8%AA%E4%BA%BA/GitHub/SlateSync/test-support/baseline/capture-visuals.mjs:48:39)
    at listOnTimeout (node:internal/timers:605:17)
    at process.processTimers (node:internal/timers:541:7)
```

## Integrity facts

- The cached `electron-v43.3.0-darwin-arm64.zip` SHA-256 is
  `ee939d1564d83d61032b3b3cb23af4e46005a4900c91f0695f7ed793f0ce6e83`,
  matching the exact entry in `node_modules/electron/checksums.json`.
- The unchanged visual-test SHA-256 is
  `b1877f7f824ab705a01a24cb78f1d6b4bccfc7bfd4bfe376fd6170cb5ad6e5a4`.
- The capture harness staged output only beneath a fresh OS temporary
  directory and removed it after failure. The baseline visual directory still
  contains only its status README.

## Stop-condition disposition

The plan requires stopping when the exact command cannot reach a capture-ready
BrowserWindow from the desktop Terminal session. No second run, LaunchServices
fallback, production hook, placeholder, test relaxation, or golden update was
attempted.

## Post-failure validation

- `node --check test-support/baseline/capture-visuals.mjs`: passed.
- `node --test test/baseline-visual.test.mjs`: 1 test, 0 passed, 1 failed,
  0 skipped, 0 todo. The failure remains the expected `ENOENT` for the absent
  `.codex/refactor/baseline/visual/manifest.json`.
- `git diff --check`: passed.
- Protected production and visual-test hashes remained identical to the
  recorded preflight values.

## Resolution recorded on 2026-08-20

The failure above is retained as historical diagnostic evidence; it is no
longer the current result. The independent Electron ESM main script had
top-level-awaited `app.whenReady()`, preventing module evaluation from
finishing before Electron could dispatch the native ready event. The harness
now schedules capture work from the ready promise, matching the production
Main lifecycle.

After readiness was restored, two-run comparison exposed a separate
one-pixel `csv-preview` difference. Pixel analysis and production-source
inspection showed that the harness was capturing an intermediate frame of
`results.scrollIntoView({ behavior: "smooth" })`. Fixed animation-frame waiting
was replaced with an asserted scroll-stability condition. This also corrected
the semantic coverage: `result-detail` and `csv-preview` now visibly contain
their respective result panels.

The exact capture command then completed twice with 10/10 identical dimensions
and SHA-256 hashes. Run durations were 1745 ms and 1702 ms. The stable
comparison is in `comparison.json`; complete manifests are in
`run-1-manifest.json` and `run-2-manifest.json`.
