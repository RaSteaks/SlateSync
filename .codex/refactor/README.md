# SlateSync refactor authority index

Updated: 2026-08-22  
Current phase: **IP-03-08 final review approved; post-IP-02 refactor complete**
Completion Report: `evidence/IP-03-08/CONTINUOUS_COMPLETION_REPORT.md`
Final Review: `reviews/FINAL-IP-03-08.md` (**APPROVED**)

Every Architect, Implementer, and Reviewer must read this file and
`CURRENT_STATE.json` before interpreting any other file below this directory.

## Current authority

1. Architecture constraints:
   `ARCHITECTURE_INVARIANTS.md` and `COMPATIBILITY_CONTRACT.md`.
2. Approved foundation Gate: `reviews/GATE-01-02.md` (`APPROVED`).
3. Sole executable implementation package:
   `packages/IP-03-08-CONTINUOUS.md`.
4. Implementer: GPT-5.6 Luna XHigh, one continuous task.
5. Final Reviewer: GPT-5.6 Sol High, one `FINAL-IP-03-08` review after the
   complete implementation and Completion Report.

There is no executable standalone IP-03, IP-04, IP-05, IP-06, IP-07, or IP-08
package and no intermediate review Gate. Historical workstream numbers are
traceability labels only.

## File classification

| Path | Classification | How it may be used |
| --- | --- | --- |
| `CURRENT_STATE.json` | Current machine-readable authority | Resolve phase, package version, Gate, model handoff, database, and signing policy. |
| `MASTER_PLAN.md`, `EXECUTION_GUIDE.md` | Current governance | Define the continuous workflow and final review. |
| `ARCHITECTURE_INVARIANTS.md`, `COMPATIBILITY_CONTRACT.md` | Current protected contract | Binding throughout implementation; conflicts enter Decision Queue. |
| `MIGRATION_MATRIX.md`, `REPOSITORY_HYGIENE.md`, `adr/**` | Current supporting decisions | Binding where referenced by the active package. |
| `IP-03-08-TRACEABILITY.md` | Current coverage proof | Maps every effective historical IP-03—08 requirement family into the active workstreams and final validation. |
| `DECISION_QUEUE.md` | Append-only decision history plus current resolution index | Earlier OPEN text is historical; the top resolution index and later Reviewer disposition control current blocking status. |
| `packages/IP-03-08-CONTINUOUS.md` | **Sole executable package** | Luna may execute its complete union scope once. |
| `packages/IP-01——IP-08.md` | Historical requirement provenance | Cross-check coverage only; its old scopes, prerequisites, Gates, and waits are inert. |
| `packages/IP-00*`, `packages/IP-0102*` | Completed historical packages | Evidence of prior authority only; never resume them. |
| `reviews/GATE-00.md` | Historical Gate | Original findings remain audit evidence; current downstream authority comes from Gate 01-02. |
| `reviews/GATE-01-02.md` | Current admission Gate | Authorizes the continuous package. |
| `baseline/**` | Frozen compatibility/golden evidence | Do not rewrite merely to reflect current prose; change only when the active package explicitly requires a new modern baseline or strengthens an executable contract. |
| `evidence/IP-00`, `IP-01`, `IP-02`, `IP-0102` | Historical execution evidence | Never reinterpret as current instructions or overwrite old command outcomes. |
| `evidence/IP-03-08/**` | Current continuous preparation/output | Luna appends checkpoints and the final Completion Report here. |

## Non-negotiable current policies

- Preserve the Gate-approved dirty worktree; do not clean, reset, stage,
  commit, push, or switch branches during implementation.
- Keep `better-sqlite3` and all persistence formats during IP-03-08. Automated
  Node/Electron ABI preparation is the accepted solution.
- Local package validation is unsigned:
  `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`.
- Signing, notarization, publishing, identity, entitlements, and release
  targets remain protected.
- Checkpoints do not trigger a model switch. Only a true Stop Condition may
  interrupt Luna before the one Sol Final Review.
- Legacy deletion requires the active package's path/symbol-exact Continuous
  Cleanup Manifest and complete post-cleanup validation.
- `IP-03-08-SAFETY-ISOLATION-001` is closed by explicit owner acceptance of
  unprovable historical impact; the path remains quarantined and no content
  access, recovery, deletion or cleanup is authorized.

If two files appear to conflict, use this precedence order:

```text
Architecture Invariants / Compatibility Contract
→ Gate 01-02 accepted decisions
→ IP-03-08-CONTINUOUS current package
→ current ADR / Decision Queue resolution / traceability matrix
→ historical package, review narrative, baseline, or evidence
```

Historical evidence must remain truthful even when its old status has been
superseded. Do not “fix” an old failed command log; use the current resolution
index and later evidence instead.
