# IP-00 visual validation

CLASSIFICATION: **FROZEN LEGACY VISUAL VALIDATION — ACCEPTED BY GATE 01-02;
NOT THE MODERN CONTINUOUS VISUAL DELIVERABLE**.

Recorded on 2026-08-20 from
`/Users/rasteaks/Desktop/个人/GitHub/SlateSync`.

## Capture stability

- Exact capture command run twice: passed.
- First duration: 1745 ms.
- Second duration: 1702 ms.
- Captures: 10/10 dimensions and SHA-256 hashes identical.
- Dimensions: 1440×900 for every PNG.
- Total PNG bytes: 1,690,732 (below 20 MiB).
- Manifest: `verifiedAgainstPreviousRun: true` and
  `identicalCaptureCount: 10`.
- Publication: first complete run published; second run verified it without
  changing the canonical image bytes; manifest was written last.

## Commands

- `node --check test-support/baseline/capture-visuals.mjs`: passed.
- `node --test test/baseline-visual.test.mjs`: 1 passed, 0 failed, 0 skipped,
  0 todo.
- `npm run test:modern`: 2 passed, 0 failed.
- `git diff --check`: passed.
- Protected-file SHA-256 verification: passed for the visual test, production
  HTML/Renderer/CSS, Preload, and IPC handlers.

## Full-suite separation

`npm test` ran the visual assertion successfully and completed its Node phase
with 224 passed and 3 failed. The three failures are unrelated IP-0102 working
tree drift already present outside this visual package:

1. baseline package/electron-builder inventory does not match the live package;
2. baseline Electron source facts do not match the live Main source;
3. Node's native runner collects the TypeScript IP-01 skeleton without its
   TypeScript/Vitest resolution.

No test was deleted, skipped, marked todo/only, or weakened to obtain the visual
pass. No production UI, IPC, data format, dependency, or signing file was
changed by this repair.

## Follow-up validation — 2026-08-20

The historical full-suite note above records the pre-IP-0102 transition
checkpoint and is retained for auditability. After the authorized IP-01/IP-02
contract/test boundary was completed, `npm test` passed Node 227/227 and
modern 7/7. The unchanged visual assertion continues to pass 1/1. The exact
capture command was rerun twice in the current desktop session with 1,673 ms
and 1,676 ms durations; `comparison.json` and the final manifest record all
ten identical hashes/dimensions.
