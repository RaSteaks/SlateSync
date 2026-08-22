# PACKAGE: IP-02 / C01 — Local Completion Evidence

EVIDENCE STATUS: **HISTORICAL, ACCEPTED BY GATE 01-02, NON-EXECUTABLE**.
The current active package is `IP-03-08-CONTINUOUS` version `2026-08-21.2`.

Status: **COMPLETED — READY FOR GATE 01-02 RE-REVIEW**

Architecture invariant deviations: **NONE**

## Implemented boundary

- Shared Contract v1 uses named, source-derived DTOs. Scenario summaries and
  profiles, project summaries/details, library actions, scanner stats/metadata,
  CSV tables/format/edits, live/persisted recognition records, task snapshots,
  and legacy usage variants are distinct; no generic JSON bag remains.
- The compiled typed Preload exposes exactly six namespaces and maps all 27
  frozen Main channels to `Result<T>`. It exposes no generic invoke, Electron,
  filesystem/database handle, secret, or cancellation API.
- `public/electron-bridge.js` reads only `slateSync`. It is the sole production
  compatibility adapter and preserves positional/raw values, error behavior,
  exact binary ranges, and listener cleanup. There is no production
  `electronAPI` fallback.
- Two frozen Gate-00 Node fixtures are adapted only by the builder-excluded
  process setup `legacy-test-gateway.mjs`; production code does not read their
  historical fake global.

## Validation

| Evidence | Result |
| --- | --- |
| Exact success DTOs and mappings for all 27 operations | PASS |
| Validation/not-found/busy/provider/timeout/dialog/unknown matrix | PASS |
| Electron rejected-`invoke` serialization probe | PASS; custom fields stripped, message retained |
| Two subscribers/idempotent removal/no late delivery | PASS |
| Adapter success/failure cleanup | PASS |
| Production destroyed-sender behavior | PASS |
| ArrayBuffer/full view zero-copy and exact subview one-copy | PASS |
| `npm run typecheck` | PASS; strict project references |
| `npm run test:node` | PASS; 229/229 |
| `npm run test:modern` | PASS; 6/6 |
| `npm test` | PASS; no skip/todo/only |
| IP-02 exact scope verifier | PASS |

## Runtime/performance evidence

- Actual Electron 43 rejected-`invoke` facts are recorded in
  `electron-rejected-invoke.json`; `code`, `status`, and `retryable` do not
  cross when attached as custom Error fields, so the gateway does not guess.
- The 1,000-call benchmark after 50 warmups records 0.000041 ms median typed
  overhead and 0.000125 ms median legacy-adapter overhead, below 1 ms.
- Raw IPC channel strings remain in Main/compiled Preload and do not appear in
  the modern Renderer bundle.

Evidence: `performance.json`, `electron-rejected-invoke.json`,
`changed-paths.json`, contract tests, Compatibility appendix, and ADR.
