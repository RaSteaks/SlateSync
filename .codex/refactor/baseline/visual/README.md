# Visual baseline capture status

CLASSIFICATION: **FROZEN LEGACY VISUAL BASELINE — ACCEPTED BY GATE 01-02**.
This is compatibility input, not the future modern unified baseline required
by continuous Workstream 8.

Gate-00's legacy ten-state visual baseline was captured successfully on
2026-08-20 from the current repository with Electron 43.3.0. The exact command
was run twice:

```sh
./node_modules/.bin/electron test-support/baseline/capture-visuals.mjs
```

The second run reproduced all ten 1440×900 PNG dimensions and SHA-256 hashes.
`manifest.json` records `verifiedAgainstPreviousRun: true` and
`identicalCaptureCount: 10`; both runs completed in under two seconds and the
PNG total is below 2 MiB.

The harness loads the unchanged production `public/index.html`, CSS, and
Renderer with synthetic offline data. It uses OS-temporary `userData`, a
non-persistent session, a normal hidden BrowserWindow, a full document reset
before every state, explicit state/font/scroll readiness, bounded lifecycle
diagnostics, OS-temporary image staging, and manifest-last publication. Failed
or unstable runs cannot overwrite an existing complete baseline.

The original readiness deadlock came from top-level-awaiting Electron's ready
promise before ESM main-module evaluation could finish. A second source of
nondeterminism was capturing the production smooth scroll to the results
section after a fixed number of animation frames. The harness now follows the
production ready-promise lifecycle and waits for scroll stability, so the
`result-detail` and `csv-preview` images contain their actual result panels.

No production UI, IPC, data format, dependency, signing configuration, or
visual test assertion was changed. Detailed run comparison and human review
evidence is retained under `.codex/refactor/evidence/IP-00/visual/`.
