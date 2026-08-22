# Test-image tracking audit

Captured: 2026-08-21 (Asia/Shanghai)

## Classification

### Must remain available as test/golden inputs

- `.codex/refactor/baseline/visual/*.png`: 10 PNGs, each 1440×900. They are
  directly loaded by `test/baseline-visual.test.mjs` and enumerated by the
  scope verifier. These are compatibility/golden inputs, not disposable
  screenshots, and should be tracked by the eventual Owner commit.
- `.codex/refactor/evidence/IP-00/visual/*.png`: 2 historical 1440×900
  captures. The IP-0102 scope verifier names them explicitly, so they should
  remain available with the frozen evidence if that evidence tree is included
  in the eventual refactor commit.

### Required final-review evidence

- `.codex/refactor/evidence/IP-03-08/visual-contained-run-25/*.png` and
  `visual-contained-run-26/*.png`: 20 PNGs, the deterministic final pair used
  by `VISUAL-ACCESSIBILITY-REVIEW.md` and `visual-stability.json`. Keep these
  two runs available for Sol's visual/hash review. They are not generated
  product assets.

### Redundant intermediate evidence

- `visual-contained-run-1` through `visual-contained-run-24`: 240 repeated
  PNGs from iterative contained captures. They are not referenced as the
  final stable pair and should not be added merely because they exist.
- `.codex/refactor/evidence/IP-03-08/visual-run-1`: 9 preliminary PNGs. It is
  historical diagnostic evidence, not the final stable pair; retain locally
  for provenance but do not make it part of a minimal submission.

The redundant files remain on disk; `.gitignore` now excludes only their image
files, so local evidence is preserved without letting those images enter a
future commit accidentally. The manifests and other non-image evidence remain
visible to Git.

### Generated build output

`storybook-static/**` is generated Storybook output, including the bundle,
fonts, workers, and SVG assets. The whole directory is now ignored because it
is reproducible from the Storybook source and build configuration. The local
output remains available for inspection; no generated file was deleted.

Playwright's `test-results/.last-run.json` is also generated run metadata and
is ignored. The test source, fixtures, test-support scripts, and test
configuration remain visible and are not covered by this rule.

## Decision

Track the 10 baseline PNGs and the 20 final stable modern PNGs when the
refactor evidence is intentionally committed. Keep the 2 named historical
IP-00 captures only if the frozen evidence tree is being committed as a unit.
Do not track the 249 redundant/preliminary modern captures or generated
Storybook images. The image-only rules implement the image recommendation;
the broader build and test-output rules implement the generated-output
recommendation. No Git staging or commit was performed.

## Reproducible audit commands

```text
rg --files -uu .codex/refactor/baseline/visual .codex/refactor/evidence/IP-00/visual .codex/refactor/evidence/IP-03-08 storybook-static | rg -i '\.(png|jpe?g|webp|gif|svg)$'
git ls-files --others --exclude-standard | rg -i '\.(png|jpe?g|webp|gif|svg)$'
test/baseline-visual.test.mjs
test-support/refactor/verify-ip0102-scope.mjs
```
