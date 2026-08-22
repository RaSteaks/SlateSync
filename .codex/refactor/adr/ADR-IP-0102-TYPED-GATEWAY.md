# ADR IP-0102: Typed Preload gateway and legacy compatibility boundary

Status: accepted and frozen by Gate 01-02 on 2026-08-21

Authority context: frozen foundation input to `IP-03-08-CONTINUOUS` version
`2026-08-21.2`; it is not a resumable IP-0102 package.

## Decision

The renderer-facing source of truth is a typed `window.slateSync` object with
six domain namespaces. Each request is mapped to one frozen Main channel and
returns `Result<T>`; rejected transport calls are converted to a redacted
`AppError` at the Preload boundary. Recognition progress remains an event with
an idempotent unsubscribe and is not a cancellation API.

Electron's sandboxed Preload loader cannot require a second local application
module, so BrowserWindow loads the single compiled CommonJS
`out/preload/index.cjs` entry directly. `electron/preload.cjs` remains only as
an explicit transition marker and is not a second executable path.
`public/electron-bridge.js` is the only production
temporary compatibility adapter: it converts the legacy positional calls and
throwing behavior back to the values expected by the unchanged legacy UI. The
active Preload does not create `window.electronAPI`, and the adapter reads only
`window.slateSync`. Frozen Node fixtures use a builder-excluded process setup
module instead of adding a production fallback; both adapters may be removed
only by Workstream 9 of the current continuous package after its exact Cleanup
Manifest proves safety.

## Consequences

- Main handlers, raw IPC names, persistence formats, security flags, timeout /
  retry behavior, recognition progress payloads, and binary byte ranges stay
  unchanged.
- Raw IPC, Electron objects, filesystem/database handles, and provider secrets
  remain confined to Main/Preload. The modern Renderer bundle contains none of
  them.
- Result wrapping and legacy unwrapping are explicit boundaries, so no second
  global, generic invoke function, or duplicate handler is needed.
- Shared DTOs model the sanitized Main results; an unprovable field remains a
  stop condition rather than an inferred public shape.
- Electron 43 rejected-`invoke` evidence shows custom Error fields are stripped.
  The gateway preserves safe fields when present but does not infer missing
  codes/status/retryability from messages.
- Native SQLite remains unchanged. Named Node/Electron rebuild hooks prepare
  the ABI required by each runner, and Electron smoke restores Node ABI in its
  outer `finally`.

## Validation

`test/refactor/ip-02/contract.test.ts`, `test/electron-bridge.test.mjs`, the
baseline IPC transition assertions, exact binary-range tests, progress
listener lifecycle tests, destroyed-sender test, actual rejected-invoke facts,
Node/Vitest suites, and production default/modern/fallback/unsigned-package
Electron smoke provide the implementation evidence. Sol independently reran
the required suite and accepted this decision in `reviews/GATE-01-02.md`.
