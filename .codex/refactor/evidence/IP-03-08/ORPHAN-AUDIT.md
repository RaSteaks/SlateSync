# IP-03—IP-08 Orphan Audit

Recorded: 2026-08-21 (Asia/Shanghai)

## Result

The audit completed with no safe deletion target. The exact cleanup deletion
set in CONTINUOUS_CLEANUP_MANIFEST.md is empty, so no source, route, IPC
channel, CSS token, asset, test, dependency, script, package resource, or
generated evidence path was removed.

The audit intentionally treats an item as retained when it is referenced by
production composition, bounded fallback, version-1 migration, compatibility
tests, package contents, or evidence. A filename containing legacy or
fallback is not evidence of orphanhood.

## Reference findings

| Surface | Exact evidence | Finding | Disposition |
| --- | --- | --- | --- |
| Renderer entry | electron/main.mjs#selectRendererEntry; src/main/renderer-entry.ts#selectRendererEntry; test/refactor/ip-01/skeleton.test.ts | Modern default and bounded legacy recovery are both exercised. | Retain |
| Preload/gateway | electron/preload.cjs; public/electron-bridge.js#legacyError; test/electron-bridge.test.mjs | The approved one-Preload gateway and all 27 compatibility mappings remain live. | Retain |
| CSV Worker | public/csv-worker.js#self.onmessage; public/csv-worker-client.js#createCsvWorkerClient; src/renderer/services/csv-worker-service.ts#CsvWorkerService | Worker protocol is used by both compatibility and modern paths; the fallback is infrastructure-only. | Retain |
| PDF Worker/resources | src/renderer/workers/preparation.worker.ts#preparePdf; public/vendor/pdfjs/pdf.mjs; public/vendor/pdfjs/pdf.worker.mjs | Both modern preparation and legacy packaged fallback reference these exact resources. | Retain |
| Persistence/migration | lib/project-library.mjs#migrateLegacyData; test/baseline-persistence.test.mjs; test/fixtures/baseline/persistence/legacy-migration.json | Version-1 migration and source integrity require these symbols and fixtures. | Retain |
| Authorized runtime dependencies | src/renderer imports of zustand, lucide-react, @tanstack/react-table, and @tanstack/react-virtual | Each authorized runtime dependency has direct source usage. | Retain |
| Authorized validation dependencies | package.json scripts; .storybook/main.ts; playwright.config.ts; vitest.config.ts; test/refactor/ip-03-08/* | Storybook, Playwright, and Vitest packages are directly used by validation. | Retain |
| Native resources | node_modules/better-sqlite3/build/Release/better_sqlite3.node; packaged ASAR/resource inspection | better-sqlite3 and platform native resources are required by the approved ABI lifecycle/package path. | Retain |
| Optional WASM resources | package-lock.json entries for @napi-rs/wasm-runtime and @tybys/wasm-util; npm ls reports platform-optional extraneous state on this macOS install | These are optional transitive resources from WASM bindings; they are not direct dependency-removal candidates and were not changed. | Retain; review separately if the lockfile is intentionally regenerated |
| Evidence outputs | .codex/refactor/evidence/IP-03-08/visual-contained-run-1 through visual-contained-run-26; storybook-static; test-results; dist/mac-arm64/SlateSync.app | The paths are validation history or package artifacts, not runtime orphans. | Retain |

## Checks performed

- rg reference search covered electron, src, public, test, test-support,
  .storybook, package.json, vite/vitest/playwright configuration, and
  electron-builder.yml.
- node test-support/refactor/verify-ip0308-scope.mjs passed with
  changed=503, deleted=0, manifestDeletions=0, and an exact lockfile
  root match.
- npm ls --depth=0 --omit=optional showed all direct declared dependencies
  at the lockfile versions. It also reports the platform-optional
  @napi-rs/wasm-runtime/@tybys/wasm-util chain as extraneous in this macOS
  working tree; no deletion is authorized because the lockfile retains the
  optional graph and package inspection must remain platform-safe.
- No unreferenced production export, IPC channel, CSS token, package script,
  migration reader, or test was promoted to deletion.
- No user Project Library was opened, parsed, hashed, copied, migrated,
  archived, deleted, or rewritten by this audit.

## Decision

The orphan audit is non-blocking for this run because it found no safe
manifest-listed deletion. The optional WASM npm-tree observation is retained
as known technical debt and is not “fixed” by removing packages or rewriting
the lockfile during IP-03—IP-08.
