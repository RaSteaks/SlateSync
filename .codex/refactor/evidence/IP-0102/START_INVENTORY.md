# IP-0102 Batch Start Inventory

EVIDENCE STATUS: **FROZEN HISTORICAL START SNAPSHOT — NOT CURRENT SCOPE
AUTHORITY**. Continuous implementation must record a new start snapshot as
required by `IP-03-08-CONTINUOUS` version `2026-08-21.2`.

Recorded for the resumed implementation batch before the final validation
pass. The authorized baseline head is `c7dafa4d972e5eb7be61f00e2b546d6826e70c87`.

The worktree already contained the Architect-owned Gate-00/batching documents,
baseline fixtures/evidence, and the partial IP-01 skeleton that the package
explicitly permits IP-02 to extend. Those files were preserved in place; no
reset, checkout, clean, stage, commit, branch switch, or user-data operation
was performed.

The original narrative inventory used broad directory notation and was not
auditable enough for Gate 01-02. The corrected read-only verifier now embeds
path-exact sets named `architectStart` and `gate00`; no directory prefix or
generated-artifact exemption is accepted. The exact implementation ownership
lists are also recorded in:

- `evidence/IP-01/changed-paths.json`
- `evidence/IP-02/changed-paths.json`
- `evidence/IP-0102/changed-paths.json`

Run all three exact checks with:

- `node test-support/refactor/verify-ip0102-scope.mjs --scope=ip-01`
- `node test-support/refactor/verify-ip0102-scope.mjs --scope=ip-02`
- `node test-support/refactor/verify-ip0102-scope.mjs --scope=ip-0102`

The verifier resolves the complete current `git diff` plus untracked set and
fails any path absent from those exact matrices. It separately rejects
`lib/**`, unapproved Electron/public production paths, root `.tsbuildinfo`, and
generated JS/declarations/maps under `src/shared/**`.
