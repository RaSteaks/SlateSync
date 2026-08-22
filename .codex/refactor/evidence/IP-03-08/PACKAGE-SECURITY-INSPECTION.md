# Package / Security / Native Resource Inspection

Inspection date: 2026-08-21

## Package

- Command: `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`
- Result: exit 0; Electron Builder 26.15.3; `dist/mac-arm64/SlateSync.app` produced; code signing explicitly skipped by the required environment variable.
- Packaged `package.json`: `slatesync@0.1.0`, `main: electron/main.mjs`.
- App ASAR contains `electron/**`, compiled `out/main`, `out/preload`, `out/renderer`, `out/shared`, `public/**`, `package.json`, and `slatesync.config.json`; extra resources contain `app/scripts/**`, `app/bin/vision-ocr`, and `app/slatesync.config.json`.
- Packaged native resources include the Electron ABI `better-sqlite3` `darwin-arm64-148/better-sqlite3.node` and the configured Release unpack path. The automated lifecycle test, not manual file copying, prepared the native module.
- `pdfjs-dist` resources and the compiled preparation Worker are present in the package inventory.

## Security / navigation

- Raw ASAR scan found no `sk-...` or `sk-or-v1-...` credential-shaped value and no non-empty API-key assignment matching the checked provider names.
- Production and packaged smoke both exercised one BrowserWindow, the typed `slateSync` namespace, missing-project error handling, external/file navigation denial, and the modern/fallback renderer markers.
- E2E and visual runners use empty provider environment variables, temporary profiles and temporary Libraries; no network or production hook is used.

## Known packaging notes

- Electron Builder reports duplicate transitive dependency references and the existing Storybook chunk-size warning. They do not change runtime contracts or package identity.
- The existing electron-builder `asarUnpack` glob includes the dependency's build artifacts (including its shipped test extension) as part of the unchanged better-sqlite3 package tree; no hand-copied `.node` file was introduced.

## Final post-cleanup reinspection

- The required unsigned directory package was rebuilt after the no-op cleanup:
  exit 0, Electron Builder 26.15.3, app identity and release configuration
  unchanged.
- Current ASAR inventory contains 5,523 entries and includes electron/main.mjs,
  out/preload/index.cjs, out/renderer/index.html, the preparation Worker,
  public/index.html, public/vendor/pdfjs/pdf.worker.mjs, and package.json.
- Current packaged package metadata is slatesync@0.1.0 with main
  electron/main.mjs. The native better_sqlite3.node is present at the
  Electron 148 unpacked resource path.
- The final raw text scan found zero matches for sk- credential-shaped
  values, sk-or-v1 values, OPENAI_API_KEY, OPENROUTER_API_KEY,
  TOKENPLAN_API_KEY, or DASHSCOPE_API_KEY assignments.
- Final packaged smoke passed in an isolated desktop session, including
  typed namespace, navigation denial, missing-project error mapping,
  native SQLite, and modern packaged renderer readiness.
