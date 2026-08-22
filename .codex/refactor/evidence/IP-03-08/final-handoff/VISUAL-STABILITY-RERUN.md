# Final-handoff visual stability rerun

Recorded: 2026-08-21 (Asia/Shanghai)

- First root: `.codex/refactor/evidence/IP-03-08/final-handoff/visual-rerun-1`
- Second root: `.codex/refactor/evidence/IP-03-08/final-handoff/visual-rerun-2`
- Capture commands: existing `capture-visual-baseline.mjs`, with only
  `SLATESYNC_VISUAL_OUTPUT` redirected into the C01 evidence directory.
- Result: `FINAL_HANDOFF_VISUAL_STABILITY_OK 10`.

| PNG | Bytes | SHA-256 | Identical |
| --- | ---: | --- | :---: |
| `01-project-library-empty-dark-1440x900.png` | 75473 | `1cfcbbafd38f081364607ba7756ba5c620d7d70c16ff46afebb8c9d974f5be07` | yes |
| `02-new-project-dialog-dark-1440x900.png` | 93732 | `aea0760910c26b7eaa82bf864baea4df5b9b0ba54417c5937acd135f19a099ee` | yes |
| `03-project-library-light-1440x900.png` | 75319 | `f2945e6532bf83e6d41d64de93a6cd7668e1bcd6c90f71f472c758de65ee6d59` | yes |
| `04-project-library-compact-light-960x600.png` | 65544 | `72fb5a7b665150017f3f5b28b8a51fc4b96b5fd35eb82ea02d654ae3647b11a8` | yes |
| `05-workspace-empty-compact-light-960x600.png` | 67761 | `cb1a41f08d17768e068d1cc00f55efaf71be10bd8ddd16e897cd4ebc2266e9ac` | yes |
| `06-global-settings-light-960x600.png` | 94561 | `ef4ef253bb9da1a7cdb3ec04f3131a8745faba9c84f8e4e576ecce0ec4ebd2de` | yes |
| `07-project-settings-light-960x600.png` | 72822 | `112b74edfef5997cc4addafb873be0f56a18a674c802cec091371f2ad3e5b7f6` | yes |
| `08-project-settings-error-light-960x600.png` | 70184 | `ee05a477e5896766c29da37c594b2a6d63d16ce64cd4801af47a2a3e0e1a4c16` | yes |
| `09-workspace-dark-reduced-motion-1440x900.png` | 128366 | `440081a022652f9cbb65b660cdbae6d92e875e2a890172caa9f053f46dafc064` | yes |
| `10-project-library-archived-dark-1440x900.png` | 88395 | `e43da91a0f1f123146e504fe28d5662329871fc342959ccea992ae22f4e300b8` | yes |

Manual inspection used the first root's dialog, global-settings, and reduced-
motion workspace states. No placeholder image or auto-accepted mismatch was
used.
