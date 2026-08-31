# SlateSync Compatibility Contract (IP-00 Baseline)

Status: **CURRENT BINDING CONTRACT — IP-00 behavior baseline plus Gate 01-02
typed-gateway freeze**
Baseline commit: `c7dafa4d972e5eb7be61f00e2b546d6826e70c87`
Captured on: 2026-08-18

Authority note (2026-08-21): read this document through its Gate 01-02
appendix. Sections 1–9 intentionally preserve the pre-migration behavior that
the new architecture must reproduce; statements there about `electronAPI` or
the absence of React describe the historical compatibility input, not the
approved current transport. Section 10 freezes the current
`window.slateSync`/compiled-Preload transition. The sole executable package is
`packages/IP-03-08-CONTINUOUS.md` version `2026-08-21.2`; see `README.md` and
`CURRENT_STATE.json`.

This document records the Electron-only application's protected behavior. It
is not permission to restore a historical implementation. The continuous
package may replace implementation only while preserving every applicable
behavior here and passing the one Sol Final Review.

### 2026-08-25 OCR-first pipeline amendment

The historical PDF input statements below remain frozen evidence and are not
rewritten. The current product pipeline intentionally supersedes their direct
provider-routing behavior: a user PDF is always rasterized locally into ordered
page images, local Vision/PaddleOCR is awaited, and OCR evidence is sent with
those images to the selected visual model. The original PDF is never a model
input. Optional OCR failure may continue with page images and a persistent
warning (`本地 OCR 不可用，已改用页面图片直接识别；识别精度可能下降。`); the
warning is retained in progress, results, task OCR summaries, and diagnostics. An
explicitly required OCR engine still blocks recognition.
Legacy requests containing `pdfDataUrl` are rejected before any provider call.

The repository root has no physical `AGENTS.md` at this baseline. The active execution rule is: after editing code, add/update comments for non-obvious architecture, ownership, concurrency, and compatibility behavior.

## 1. Runtime and ownership

- `electron/main.mjs` is the Electron entrypoint and composition root. It loads environment/configuration, provider keys, machine settings, Project Library/runtime, IPC handlers, and the sandboxed `BrowserWindow`.
- `public/index.html` loads the single-page Renderer from `public/app.js`. The Renderer is DOM JavaScript, not React or TypeScript.
- `electron/preload.cjs` is loaded with `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`, `webSecurity: true`, and `allowRunningInsecureContent: false`. The Renderer uses `globalThis.electronAPI` through `public/electron-bridge.js`.
- The Main window defaults to 1440×900 and has minimum dimensions 960×600. External navigation and new-window creation are denied; file navigation is limited to the app `public` directory.
- Main owns filesystem access, native dialogs, SQLite, Project Library/project runtime, task/diagnostic/scenario persistence, secrets, provider configuration, OCR orchestration, recognition timeout/retry/concurrency, and model requests.
- The CSV module Worker owns the long-lived decoded Resolve table and CPU-heavy CSV decode/merge/normalize/encode work. `public/app.js` retains a fallback processor if Worker construction fails.
- Current code does not expose the target `window.slateSync` namespace or `Result<T>` error envelope. The current `electronAPI`/throwing IPC surface is the compatibility baseline to migrate deliberately in IP-02; IP-00 does not change it.

Source references: `electron/main.mjs` (`initialize`, `createWindow`), `electron/preload.cjs`, `public/electron-bridge.js`, `public/app.js`, `public/csv-worker.js`, `public/csv-worker-client.js`.

## 2. Recognition contract

### Inputs and routing

`electron/ipc-handlers.mjs` accepts a recognition body and resolves project-owned settings before calling `recognizeSlate` from `lib/ai-client.mjs`. Provider/model/prompt are task inputs subject to project defaults; project-owned accuracy mode, field formats, and Comments settings remain authoritative. Current recognition media input is a single image or grouped page images; PDF files are converted to grouped page images by the local Preparation Worker before this boundary. A slate CSV may be supplied as high-confidence context.

Configured providers are OpenAI Responses, OpenRouter Chat Completions, Token Plan, DashScope, and a custom OpenAI-compatible provider. Provider API keys are read from environment variables and/or Main-owned `provider-keys.json`; keys are never returned in public configuration. Model discovery can fall back to the static catalog when a non-400 discovery request fails.

### Normalization and result rules

- `lib/schema.mjs` validates/normalizes the model result into `sheetTitle`, `records`, and `warnings`.
- Each record receives an application-generated ID; baseline comparisons must canonicalize IDs and durations.
- `scene` preserves all scene tokens, uppercases suffix letters, and joins multiple scenes with `" / "`; numeric scenes are padded to configured width (default `XXX`).
- `shot` and `take` are numeric, padded to configured width (default `XX`), and never truncate numbers wider than the configured width. Full-width digits and Chinese numerals are normalized.
- `takeStatus` maps good marks (`☑/√/✓/✔`) to `过`, triangle marks (`△/▲`) to `保`, and explicit X marks (`X/×/✕/✖`) to `废条`; unknown/blank is `null`.
- Recognition records preserve source page order. For image groups, page results are collected in input order even when requests finish out of order. Rasterized page records carry `sourcePage`.
- Missing merged Scene/Shot values can inherit from the previous same-reel record. Sequence reconciliation and warnings are part of the current result semantics; the application must not guess values that remain unresolved.
- High accuracy can launch primary and independent audit/review stages. It may recover omissions, resolve conflicts, lower confidence, or remove audit-only rows according to `lib/ai-client.mjs`; IP-00 freezes these stages and does not simplify them.

Source references: `lib/schema.mjs` (`normalizeSlateResult`, `formatSlateResultFields`), `lib/ai-client.mjs` (`recognizeSlate`, `mergePageResults`, `inheritSceneAndShot`, `reconcileRecordSequences`, `pageConcurrency`).

### Progress, timeout, retry, and cancellation

- Recognition progress is sent from Main on the `recognition-progress` event. Current phases include preparation/recognition/audit/review/page completion/completion and carry a percentage plus page counters/messages where applicable.
- `MODEL_REQUEST_TIMEOUT_MS` defaults to 180000 ms and is clamped to 30000–3600000 ms. `MODEL_REQUEST_MAX_RETRIES` defaults to 1 and is clamped to 0–3. `MODEL_PAGE_CONCURRENCY` defaults to 2 and accepts 1–6. `MAX_CONCURRENT_RECOGNITIONS` defaults to 1 and accepts 1–16.
- `postJson` uses `AbortSignal.timeout`. A `TimeoutError`, or an `AbortError` whose details identify a timeout, is retryable. The default is exactly one retry. Exhaustion becomes a readable provider error with HTTP-like status 504 and an attempt count. Other failures are not timeout retries and become provider connection errors.
- `createTaskLimiter` rejects excess concurrent recognition with status 429. Project write/archive leases also reject unsafe concurrent transitions.
- There is no public `cancel-recognition` IPC channel and no Renderer cancellation method in the current preload bridge. Cleanup consists of `recognizeApi` registering a progress listener for the invocation and always removing it in `finally`; preload also removes a previous listener before registering a new one. IP-00 must not add cancellation or alter late-response behavior.

Source references: `lib/ai-client.mjs` (`postJson`, `modelRequestTimeoutMs`, `modelRequestMaxRetries`, `isRequestTimeout`, `mapWithConcurrency`), `electron/env-loader.mjs`, `electron/ipc-handlers.mjs`, `electron/preload.cjs`, `public/electron-bridge.js`.

### OCR behavior

PaddleOCR and macOS Vision OCR are optional evidence layers. `auto`, explicit enable/disable, required/optional failure, cache grouping, confidence/coordinate evidence, and direct-PDF restrictions are current behavior. Optional failure degrades to multimodal recognition; required failure rejects. OCR Python path is persisted in Main machine settings, never exposed as a secret in public config.

Source references: `lib/ocr/paddleocr.mjs`, `lib/ocr/vision.mjs`, `lib/config.mjs`, `electron/ipc-handlers.mjs`, `test/ocr.test.mjs`, `test/vision-ocr.test.mjs`.

## 3. Preload and IPC contract

The current exposed object is `window.electronAPI`. It contains these request methods and exact channel names:

| Renderer method | IPC channel | Current argument shape |
| --- | --- | --- |
| `getConfig()` | `get-config` | none |
| `saveProviderKey(provider, apiKey)` | `save-provider-key` | `{ provider, apiKey }` |
| `getModels(providerId, forceRefresh)` | `get-models` | `{ providerId, forceRefresh }` |
| `recognize(requestBody)` | `recognize` | recognition body |
| `saveFile(defaultFilename, data)` | `save-file` | `{ defaultFilename, data }` |
| `selectDirectory()` | `select-directory` | none |
| `scanSlateDirectory(dirPath, expectedKeys, maxDepth)` | `scan-slate-directory` | `{ dirPath, expectedKeys, maxDepth }` |
| `listProjects()` | `list-projects` | none |
| `getLibraryInfo()` | `get-library-info` | none |
| `importProjectLibrary()` | `import-project-library` | none |
| `exportProjectLibrary()` | `export-project-library` | none |
| `changeLibraryLocation()` | `change-library-location` | none |
| `createProject(project)` | `create-project` | project body |
| `loadProject(id)` | `load-project` | `{ id }` |
| `updateProject(project)` | `update-project` | project body |
| `archiveProject(id)` | `archive-project` | `{ id }` |
| `restoreProject(id)` | `restore-project` | `{ id }` |
| `listTasks(projectId)` | `list-tasks` | `{ projectId }` |
| `loadTask(projectId, id)` | `load-task` | `{ projectId, id }` |
| `saveTask(projectId, task)` | `save-task` | `{ projectId, task }` |
| `deleteTask(projectId, id)` | `delete-task` | `{ projectId, id }` |
| `listScenarios(projectId)` | `list-scenarios` | `{ projectId }` |
| `loadScenario(projectId, id)` | `load-scenario` | `{ projectId, id }` |
| `importScenario(projectId, profile)` | `import-scenario` | `{ projectId, profile }` |
| `getOcrSettings()` | `get-ocr-settings` | none |
| `saveOcrSettings(settings)` | `save-ocr-settings` | settings body |
| `checkOcr(pythonPath)` | `check-ocr` | `{ pythonPath }` |

Recognition progress is an event channel named `recognition-progress`, not a request/response method. `onRecognitionProgress(callback)` installs one listener and removes a prior listener; `removeRecognitionProgressListener()` removes the current listener. Main checks `event.sender.isDestroyed()` before sending progress. Request failures are thrown through `ipcRenderer.invoke`; they are not wrapped in the target `Result<T>` union.

`saveFile` accepts a typed-array/`ArrayBuffer` payload and Main writes it as bytes. Legacy arrays remain accepted by Main for compatibility. Native dialogs are Main-owned: save CSV, select material directory, import Project Library, select Library storage directory, and export Project Library.

Source references: `electron/preload.cjs`, `public/electron-bridge.js`, `electron/ipc-handlers.mjs`, `electron/file-dialogs.mjs`.

## 4. CSV contract

`public/resolve-csv.js` is the current CSV implementation. `public/csv-background-tasks.js` and `public/csv-worker.js` run it in a long-lived module Worker when available.

- Decoder detects UTF-8, UTF-8 BOM, UTF-16LE BOM, and UTF-16BE BOM; it retains encoding, BOM, delimiter, and newline metadata for encoding.
- Parser preserves header order, all original columns, row order, quoted cells, embedded delimiters, and embedded newlines. Invalid quote structure is rejected.
- Merge matches canonical reel/video keys and writes normalized Scene/Shot/Take and canonical Comments while preserving unrelated columns/rows. Multi-scene values are preserved according to current Resolve mapping rules. Conflicting or incomplete matches do not fabricate rows.
- Field formats default to `scene: XXX`, `shot: XX`, `take: XX`; configured X templates control minimum width and wider numeric values remain intact.
- Resolve Comments allow only configured good/hold markers (`_OK`/`_KP` by default); `废条`, `null`, and unrecognized manual values become empty when canonicalization is enabled.
- Manual preview edits are sparse `row:column` keys and are applied only to touched rows. Preview task snapshots store the table, filename, edits, slate metadata, warnings, missing keys, and directory name.
- Standalone export creates a Resolve table from complete records and rejects an empty result.
- Worker messages are `{ id, task }`; byte results are transferred as an exact `ArrayBuffer` range. The Worker retains metadata between requests, clears it explicitly, classifies task errors, and rejects pending requests on error/termination. Renderer fallback is only an infrastructure fallback.

Source references: `public/resolve-csv.js`, `public/csv-background-tasks.js`, `public/csv-worker.js`, `public/csv-worker-client.js`, `public/task-persistence.js`, `public/app.js`.

## 5. Persistence and Project Library contract

### SQLite

`lib/sqlite-store.mjs` opens databases with `journal_mode = WAL`, `foreign_keys = ON`, and `busy_timeout = 5000`. It creates private directories (`0700` where supported) and database files (`0600` where supported).

- Legacy database filename: `slatesync.sqlite`.
- Library database filename: `library.sqlite`, containing `library_meta` and `projects` plus the updated-at index.
- Project database filename: `project.sqlite`, containing `app_meta`, `project_meta`, `tasks`, `diagnostic_sessions`, `scenario_profiles`, and `scenario_observations` plus their current indexes/foreign key.
- `tasks.data_json` and `diagnostic_sessions.data_json` retain complete JSON payloads. SQLite is authoritative; JSON files under `tasks/` and `diagnostics/` remain compatibility snapshots and are imported when needed.
- Legacy JSON directory migration is insert-if-missing and ignores malformed snapshots so one corrupt legacy file does not prevent startup.

### Tasks and settings

`lib/task-store.mjs` saves a task with a validated alphanumeric/underscore/hyphen ID, preserves `createdAt`, updates `updatedAt`, writes SQLite and an atomic JSON snapshot, lists projections ordered by `updated_at DESC`, and deletes both database row and snapshot. `createTask()` is the complete default field contract; its fields include project ownership/settings snapshot, recognition inputs/results, OCR/diagnostic information, CSV preview table/edits, metadata, status, and timestamps.

`electron/settings-store.mjs` writes `<userData>/settings.json` atomically with `libraryPath`, `ocrPythonPath`, `ocrSetupCompleted`, and `ocrSetupSkipped`. Provider keys are separately stored at `<userData>/provider-keys.json` with restrictive permissions. Machine settings are not project content.

### Project Library

`lib/project-library.mjs` creates a portable directory ending `.slatesync-library`:

```text
<Library>.slatesync-library/
├── library.json
├── library.sqlite
└── Projects/
    └── <project-id>/
        ├── project.json
        ├── project.sqlite
        ├── tasks/*.json
        └── diagnostics/*.json
```

Library and project format versions are `1`. The default project ID is `project-default` and cannot be archived. `library.json` records library ID/name/formatVersion/createdAt; `project.json` records project ID/library ID/name/description/formatVersion/createdAt/updatedAt. Project settings are persisted in `project_meta`, not duplicated in the library index. Separate project databases enforce project isolation. Legacy global data is migrated once to the default project with the `legacy_migration_v1` marker, and the source remains intact.

The default Library location is directly under the application-data root; a prior `<userData>/Libraries/Local SlateSync Library.slatesync-library` location is preferred only when the new default does not exist. Import/export validates the suffix and manifest/database before copy. Changing the active Library persists the path, closes connections, and relaunches Electron.

Source references: `lib/sqlite-store.mjs`, `lib/task-store.mjs`, `lib/project-library.mjs`, `lib/project-library-transfer.mjs`, `lib/project-runtime.mjs`, `electron/settings-store.mjs`, `electron/key-store.mjs`, `electron/main.mjs`.

## C02 modern projection clarification — 2026-08-22

The modern Renderer does not redefine this contract. Opening a project reads
project details, scenario summaries and task summaries in parallel from the
same typed gateway, then publishes project/route projections atomically. Task
switching flushes the sole serialized save writer, primes or clears the same
retained CSV Worker before publishing the restored table, and clears absent
slate/recognition/metadata/export projections. Route unmount terminates Workers
and releases large view projections after the immutable pending save snapshot
has been captured. These are lifecycle corrections only; no IPC operation,
TaskData field, CSV byte rule or Main authority changed.

## 6. Environment and configuration contract

Development loads `.env` from the project root; packaged builds load a userData `.env`. `SLATESYNC_CONFIG_PATH` selects the workflow config in development; packaged builds use the bundled `slatesync.config.json`. Main assigns `SLATESYNC_PROJECT_DIR` to the source root in development or bundled app resource root when packaged. API keys may be overridden at runtime by Main-owned provider keys; the Renderer receives only readiness/public model data.

The complete variable inventory, defaults, ranges/enums, and secret classification is in `.codex/refactor/baseline/contracts/environment.json`. It includes every `.env.example` variable and source-only runtime variable, including OCR and provider transport settings. No local secret values are part of the baseline.

## 7. Electron builder and release contract

`package.json` is private version `0.2.0`, requires Node `>=20.19`, uses `electron/main.mjs`, and defines the current check/test/dev/build/release commands. `electron-builder.yml` uses app ID `com.slatesync.app`, product name `SlateSync`, output `dist`, build resources `build`, macOS DMG/ZIP targets for arm64/x64, tracked icon/entitlements, and the current `files`, `extraResources`, and `asarUnpack` rules.

The CI baseline installs with `npm ci`, runs `npm run check` and `npm test`, and uses Node 22. macOS release additionally compiles the Vision OCR Swift binary for each architecture, validates source/tests, runs `electron-builder --mac --<arch> --publish never`, uploads DMG/ZIP artifacts, and publishes them in a separate job. `public/vendor/pdfjs/` is generated by `postinstall`; `bin/vision-ocr` is generated by release setup and ignored by Git. The complete structured inventory is in `.codex/refactor/baseline/contracts/build.json`.

## 8. Frozen UI states

The current page routes are `projects`, `workspace`, `project-settings`, and `global-settings`, with Project Library, workspace/results, settings cards, New Project dialog, and Local OCR setup overlay. The current visual baseline is light-only (`color-scheme: light`), 1440×900, and is recorded under `.codex/refactor/baseline/visual/`. This contract does not infer the target dark/light Design System from the Master Plan.

## 9. Change rule

Any later change to the behaviors above must be covered by a new Implementation Package or Correction Package, an explicit compatibility test/update, and the relevant Sol Review Gate. A test or golden fixture must never be weakened to hide a behavior change.

## 10. IP-0102 typed gateway transition (Gate 01-02 approved and frozen)

The IP-0102 foundation keeps every item above as the compatibility input and
adds one active, typed Renderer gateway. Because Electron's sandboxed Preload
cannot `require` a second application-local module, BrowserWindow loads the
single compiled `out/preload/index.cjs` entry directly; the historical
`electron/preload.cjs` is a non-executable transition marker. The compiled
Preload exposes only
`window.slateSync`, grouped into `app`, `projects`, `tasks`, `recognition`,
`files`, and `settings`. Its request methods use the exact channel mappings in
`.codex/refactor/baseline/contracts/ipc.json` and return `Result<T>`; Main
handlers and raw channel names are unchanged.

`public/electron-bridge.js` is the sole temporary adapter. It maps the legacy
positional calls to typed request objects, unwraps successful `Result<T>` data
to the same raw values, reconstructs compatible thrown errors, and removes
recognition progress listeners in `finally`. It reads only `slateSync`; there
is no production `electronAPI` fallback or second transport. Two frozen
Gate-00 Node fixtures are adapted by the process-only
`test-support/refactor/legacy-test-gateway.mjs`, which is outside builder
inputs. IP-08 is the removal marker for both temporary test/Renderer adapters,
not an authorization to change the legacy UI in IP-0102.

An actual Electron rejected-`invoke` probe confirms Electron 43 transports the
message and stack but strips custom `code`, `status`, and `retryable` fields.
The Preload therefore preserves those fields when a transport supplies them,
but correctly emits `UNKNOWN`/non-retryable when Electron did not deliver
them; it never guesses a provider or busy code from localized message text.

The typed contract preserves binary `ArrayBuffer`/view ownership, event
payloads, timeout/retry behavior, persistence/data formats, security flags,
and all 27 existing operations. No automatic retry, cancellation method,
filesystem handle, secret, raw Electron object, or generic invoke entrypoint is
introduced. The observed Node ABI 137 and Electron ABI 148 are prepared by
separate named npm lifecycles around the same unchanged SQLite implementation;
the values are runtime observations rather than hard-coded contracts. Every
Electron smoke restores the Node binding in `finally`, and
`test:native:abi` independently probes both sides. Gate 01-02 approved this
appendix and froze Shared Contract v1 on 2026-08-21. Database-driver policy and
the deferred `node:sqlite` evaluation are recorded in
`adr/ADR-DATABASE-RUNTIME-ABI.md`.
