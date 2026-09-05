# Image ignore result — IP-03—IP-08 final handoff

Captured: 2026-08-21 (Asia/Shanghai)

> Historical result: broader Owner-authorized cleanup on 2026-09-05 replaced
> these narrow image rules with a generated-evidence policy and removed the raw
> capture directories from the current tree.

## Action

At the Owner's request, the root `.gitignore` was updated to prevent
redundant visual captures and reproducible generated Storybook/Playwright
outputs from entering a future commit accidentally. No image file was
deleted, moved, overwritten, staged, or committed. Ignored files remain
available on disk for local inspection.

The repository rules are deliberately narrow:

```text
.codex/refactor/evidence/IP-03-08/visual-contained-run-[1-9]/*.png
.codex/refactor/evidence/IP-03-08/visual-contained-run-1[0-9]/*.png
.codex/refactor/evidence/IP-03-08/visual-contained-run-2[0-4]/*.png
.codex/refactor/evidence/IP-03-08/visual-run-1/*.png
storybook-static/
test-results/
```

The final stable pair, baseline images, conditional historical IP-00 captures,
test source, fixtures, and test-support scripts are intentionally not ignored.

## Reproducible result

Using `git check-ignore -v` and the image-path inventory after applying the
rules:

| Class | Count | Git behavior |
| --- | ---: | --- |
| Redundant contained visual runs 1–24 | 240 | Ignored; retained on disk |
| Preliminary `visual-run-1` captures | 9 | Ignored; retained on disk |
| Generated Storybook SVGs | 4 | Ignored with `storybook-static/`; retained on disk |
| Required baseline PNGs | 10 | Visible to Git |
| Conditional IP-00 historical PNGs | 2 | Visible to Git |
| Final stable contained runs 25–26 | 20 | Visible to Git |
| Final-handoff reruns 1–2 | 20 | Visible to Git |

Therefore, `ignored_target_images=253` and `visible_target_images=52`. The
broader generated-output audit also records 54 Storybook files and one
Playwright result file under the directory rules.

Representative verification:

```text
git check-ignore -v --no-index .codex/refactor/evidence/IP-03-08/visual-contained-run-1/06-global-settings-light-960x600.png
  .gitignore:27:.codex/refactor/evidence/IP-03-08/visual-contained-run-[1-9]/*.png

git check-ignore -v --no-index .codex/refactor/evidence/IP-03-08/visual-contained-run-24/06-global-settings-light-960x600.png
  .gitignore:29:.codex/refactor/evidence/IP-03-08/visual-contained-run-2[0-4]/*.png

git check-ignore -v --no-index .codex/refactor/evidence/IP-03-08/visual-run-1/06-global-settings-light-960x600.png
  .gitignore:30:.codex/refactor/evidence/IP-03-08/visual-run-1/*.png

git check-ignore -v --no-index storybook-static/favicon.svg
  .gitignore:34:storybook-static/ storybook-static/favicon.svg

git check-ignore -v --no-index test-results/.last-run.json
  .gitignore:35:test-results/ test-results/.last-run.json

git check-ignore -v --no-index .codex/refactor/baseline/visual/project-settings.png
  no match (visible)

git check-ignore -v --no-index .codex/refactor/evidence/IP-03-08/visual-contained-run-25/06-global-settings-light-960x600.png
  no match (visible)
```

The paths above are representative names; the exact inventory is reproducible
with the first command, while the second command shows only the image paths
that remain visible to Git:

```text
rg --files -uu .codex/refactor/baseline/visual .codex/refactor/evidence/IP-00/visual .codex/refactor/evidence/IP-03-08 storybook-static | rg -i '\.(png|jpe?g|webp|gif|svg)$'
git ls-files --others --exclude-standard | rg -i '\.(png|jpe?g|webp|gif|svg)$'
```

## Owner-authorized hygiene addendum — 2026-08-22

The Owner authorized the root `.gitignore` as a standalone hygiene change.
The superseded C02 visual run PNGs are now included in the redundant-image
ignore set, while their manifests remain available as non-image evidence. The
current worktree contains 310 ignored redundant PNGs and 52 visible required
PNGs. No image was deleted or rewritten; the exact authorization is recorded
in `GITIGNORE-HYGIENE-AUTHORIZATION.md`.

This tracking adjustment does not claim the refactor is approved. It only
keeps the local evidence tree intact while making the recommended future
commit boundary explicit for Sol's review.
