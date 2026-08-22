# IP-00 visual baseline human review

CLASSIFICATION: **FROZEN LEGACY VISUAL EVIDENCE — NON-EXECUTABLE**.

- Reviewed: 2026-08-20
- Images: ten PNGs, each 1440×900
- Fixture: `synthetic-project-library-v1`
- Data isolation: all visible project, path, filename, API, model, slate, task,
  and CSV values are synthetic; no real user content or credentials are shown.

## State review

- `project-library`: active and archived synthetic projects render completely.
- `workspace-empty`: empty input and preview state render without overlays.
- `workspace-ready`: two-page synthetic slate is loaded and previewed.
- `recognition-progress`: busy overlay, stage, page count, and 68% progress render.
- `result-detail`: smooth scroll has completed and the recognition detail table,
  warnings, metrics, tabs, and download action are visible.
- `csv-preview`: smooth scroll has completed and the edited three-row Resolve
  CSV table, error row, tabs, and download action are visible.
- `project-settings`: synthetic project fields and recognition preferences render.
- `global-settings`: provider and skipped local-OCR state render without secrets.
- `new-project-dialog`: modal, backdrop, fields, and actions render completely.
- `ocr-setup-dialog`: local OCR modal, backdrop, path field, and actions render.

No clipped modal, incomplete loading layer, mixed state, placeholder golden, or
sensitive production information was observed.
