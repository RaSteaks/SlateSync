# Swift migration compatibility contract

The native implementation may change language, UI framework and process
boundaries, but must preserve these observable contracts until a recorded
decision explicitly replaces them.

## SM-09 acceptance scope — Owner decision, 2026-10-27

The Owner requested the SM-09 completion-scope and acceptance-layer revision.
[Acceptance policy v2](../../docs/sm09-acceptance-policy.md) permits a clean,
complete functional/local-package Gate PASS to support migration completion
review. Timing and FPS remain separately reported; functional, data, resource,
UI and package assertions remain mandatory. The default full release Gate and
distribution requirements are unchanged. This decision is not a candidate PASS,
phase approval or release authorization and does not unfreeze SM-05/SM-06 algorithms.

## Retained product contracts

The 2026-10-27 request to implement the recognition optimization plan authorizes
the scoped [recognition evolution decision](../../docs/recognition-contract-evolution.md):
versioned structural matching, explicit candidate confirmation, OCR-quality
images before transfer compression, and runtime/view cache reuse. V1 storage
and historical oracles remain readable; the affected current algorithms need
not reproduce the old matching and media orchestration behavior.

- Project Library and project package format version remain `1`.
- `library.sqlite`, `project.sqlite`, table/index names, WAL, foreign keys and
  busy timeout remain compatible with existing installations.
- Task/diagnostic/scenario JSON keys and compatibility snapshots remain readable.
- Resolve CSV retains encoding, BOM, delimiter, line endings, column/row order,
  quoting and untouched cell bytes semantically; golden exports remain exact.
- Recognition remains OCR-first. Original PDF bytes never go to a provider.
- Provider prompts, schemas, normalization, timeout, retry, concurrency,
  cancellation and progress meaning are ported without opportunistic cleanup.
- Global settings remain machine-local. Existing provider keys migrate to
  Keychain only after every write is verified; failure leaves the source intact.
- Project deletion retains the existing tombstone/lease/compensation safety.
- Automated tests never open the user's default Project Library.
- Windows is no longer a supported runtime, package or release target.

## Language acceptance scope — Owner decision, 2026-09-06

All phases require Chinese language and Chinese IME acceptance only. Japanese
and other languages do not require dedicated acceptance coverage. This decision
supersedes broader language coverage requirements in phase packages. Existing
file-format aliases, protocol identifiers, Unicode/emoji compatibility, and
historical executed evidence remain valid and unchanged.
