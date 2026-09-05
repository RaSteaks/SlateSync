# Swift migration compatibility contract

The native implementation may change language, UI framework and process
boundaries, but must preserve these observable contracts until a recorded
decision explicitly replaces them.

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
