# Repository build configuration and cleanup policy

Authority status: **CURRENT SUPPORTING POLICY FOR
`IP-03-08-CONTINUOUS` VERSION 2026-08-21.2**.

Updated: 2026-08-22

## Root files shown in the screenshot

The screenshot mixes source configuration with generated incremental caches.
The source configuration is intentionally split by process boundary; the
generated caches do not belong in the repository root.

| File | Keep? | Ownership |
| --- | --- | --- |
| `tsconfig.base.json` | Yes | One strict compiler policy shared by every TypeScript target. |
| `tsconfig.json` | Yes | Solution-level project-reference entry used by `tsc -b`. |
| `tsconfig.main.json` | Yes | Main's NodeNext compilation and `out/main` ownership. |
| `tsconfig.shared.json` | Yes | Runtime-neutral contracts/domain/errors compiled before consumers. |
| `tsconfig.preload.json` | Yes | Sandbox Preload type/declaration boundary. |
| `tsconfig.renderer.json` | Yes | React/DOM Renderer type/declaration boundary. |
| `vite.preload.config.ts` | Yes | Produces the single sandbox-compatible CommonJS Preload bundle. |
| `vite.renderer.config.ts` | Yes | Produces the file-protocol-safe React Renderer bundle. |
| `vitest.config.ts` | Yes | Keeps modern TypeScript/component tests separate from frozen Node tests. |
| root `tsconfig.*.tsbuildinfo` | No | Generated incremental state; already removed and redirected to ignored `out/.tsbuildinfo/**`. |

Combining the retained files would hide Main/Preload/Renderer library and
module differences, weaken project-reference ordering, or mix runtime output
ownership. Their explicit names are useful architecture, not accidental
clutter.

## Generated directories retained locally

- `out/**` is ignored, reproducible build output. Electron development and the
  current compiled Preload need it after `build:modern`; it may be regenerated
  and is never source authority.
- `dist/**` is ignored package output. The current directory contains the
  unsigned package used by Gate 01-02 evidence, so it is retained until the
  continuous implementation creates replacement package evidence.
- `node_modules/**`, `.venv-paddleocr/**`, `.paddlex-cache/**`, and `bin/**`
  are installed/generated tool dependencies. They are not source but removing
  them would force reinstall/rebuild and is not needed for repository hygiene.
- `data/**` and `.env` may contain real local settings, secrets, or user data.
  They are ignored and must never be treated as cleanup targets.

## Owner-authorized standalone `.gitignore` hygiene

On 2026-08-22 the Owner authorized the root `.gitignore` as a separate,
hygiene-only change. It excludes local `.env.*` variants (while retaining
`.env.example`), reproducible Storybook/Playwright/Vite/TypeScript output, and
redundant IP-03-08 visual captures. Required baseline images, historical IP-00
captures, final stable runs, final-handoff reruns, source, tests, fixtures and
non-image evidence remain visible.

The exact boundary and stop conditions are recorded in
`.codex/refactor/evidence/IP-03-08/final-handoff/GITIGNORE-HYGIENE-AUTHORIZATION.md`.
The change does not authorize production edits, evidence deletion, user-data
access, or Git history mutation. The prior generated Storybook and Playwright
directories were moved to recoverable `/tmp/slatesync-generated-20260822-*`
locations and remain reproducible.

## Cleanup completed

The following were verified as ignored, unreferenced, reproducible, or OS
metadata before removal:

- `tmp/slatesync-dev-runtime.mjs`: obsolete personal runtime switcher with a
  removed Node Web mode; superseded by package scripts.
- `tmp/slatesync-electron-hot.mjs`: obsolete personal watcher that did not
  rebuild modern sources and was not referenced by package scripts.
- `out/tsconfig.preload.tsbuildinfo`: stale cache from the former output path;
  the active cache is `out/.tsbuildinfo/preload.tsbuildinfo`.
- repository `.DS_Store` files: Finder metadata, already ignored and unrelated
  to build/runtime behavior.

Future cleanup must be path-exact. Do not run broad worktree cleaning, remove
ignored user data, or delete a file merely because it is generated. IP-03-08
production cleanup remains governed by its separate exact Cleanup Manifest.
