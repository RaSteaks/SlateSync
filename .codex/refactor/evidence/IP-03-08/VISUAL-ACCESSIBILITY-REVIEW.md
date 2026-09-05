# Unified Visual / Accessibility Review

Review date: 2026-08-21

> Repository cleanup note (2026-09-05): the raw capture directories and
> generated comparison JSON were removed from the current tree after review.
> This curated conclusion and the executable legacy baseline remain tracked.

## Captured states

- Final stable pair: `visual-contained-run-25/` and `visual-contained-run-26/`.
- `visual-stability.json` reports 10/10 exact PNG SHA-256 matches.
- Coverage includes dark/light Project Library, new-project dialog, compact 960×600, workspace empty, global settings, project settings, field validation error, dark reduced-motion workspace, and archived-project Library.
- Manual inspection used the final run-25 PNGs. Layout hierarchy, sidebar/toolbar ownership, card grouping, empty/error affordances, compact density, and reduced-motion workspace are visually coherent; no clipping or placeholder screenshot was used.

## Accessibility evidence

- Electron E2E `keeps keyboard focus, ARIA state, reduced motion, and route scroll bounded` passed after verifying Dialog `aria-modal`, initial focus inside the Dialog, Tab entry into the form, Escape dismissal, opener restoration, exact route scroll reset, `--ss-motion-base: 1ms`, and zero unlabeled empty icon buttons.
- Design-system component test covers focus trap, Escape, and opener restoration; `Field` error tests preserve `aria-invalid` and `aria-describedby` ownership.
- Focus rings are visible through `:focus-visible`/`focus-within` rules. Transient focus is intentionally normalized only for visual screenshots; behavior remains covered by the E2E.
- Reduced motion is implemented by semantic tokens plus transition/animation removal under `prefers-reduced-motion: reduce`.

## Contrast evidence

WCAG relative-luminance calculation for the semantic token pairs used by the final UI:

| Pair | Ratio |
| --- | ---: |
| Dark ink / surface | 16.38:1 |
| Dark muted / surface | 8.35:1 |
| Dark subtle / surface | 5.20:1 |
| Dark accent / surface | 7.02:1 |
| Light ink / surface | 15.27:1 |
| Light muted / surface | 6.61:1 |
| Light subtle / surface | 4.90:1 |
| Light accent / surface | 6.54:1 |
| Dark danger / surface | 8.00:1 |
| Light danger / surface | 5.63:1 |

All reviewed semantic text pairs meet the package's 4.5:1 normal-text target. The subtle tokens were adjusted after the initial review because their measured ratios were 4.42:1 and 4.30:1.
