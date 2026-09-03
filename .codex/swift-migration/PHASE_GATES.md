# SlateSync phase admission policy

This policy is authoritative for SM-00 through SM-09. A phase implementation
and a phase admission are separate events: passing tests does not update state,
and editing `CURRENT_STATE.json` does not manufacture evidence.

## Lifecycle

`NOT_STARTED → IN_PROGRESS → REVIEW_READY → PASS | BLOCKED → COMPLETE`

- `REVIEW_READY` means the implementation is frozen in a dedicated commit or PR.
- `PASS` means every required Gate check passed for that exact commit.
- `BLOCKED` means at least one required check is `FAIL` or unresolved
  `BLOCKED_ENV`.
- `COMPLETE` requires `PASS`, an evidence report, and Repository Owner approval.
- The next phase may become `IN_PROGRESS` only after the current phase is
  `COMPLETE`.

Rewriting history or adding product/source changes after review makes approval
stale. Because recording tracked approval metadata necessarily creates a new
commit, HEAD may follow the reviewed commit only when the complete diff is
limited to `CURRENT_STATE.json` and that phase's review report. Any other path
requires a new Gate run and Owner approval.

## Check results and exit codes

Checks use only `PASS`, `FAIL`, `BLOCKED_ENV`, and `NOT_APPLICABLE`.

- `PASS`: the command ran and its assertions succeeded.
- `FAIL`: product code, contracts, tests, or artifacts are wrong. Evidence and
  Owner approval cannot replace it.
- `BLOCKED_ENV`: an external execution condition prevented a result, such as
  cache sandboxing, an unavailable GUI session, Xcode licensing, or credentials.
- `NOT_APPLICABLE`: the package declared the check irrelevant before review.

`phase_gate.sh` exits `0` only for an approvable clean-worktree PASS, `1` for
FAIL, `2` for BLOCKED_ENV, `3` for a successful `--allow-dirty` diagnostic run,
and `64` for invalid usage or an unknown phase.

## Required workflow

1. Implement only the active phase and update its package.
2. Run `./script/phase_gate.sh SM-XX --allow-dirty` while iterating. The result
   may prove technical health but is never approvable.
3. Create a dedicated phase commit or PR. Generated results, DerivedData,
   `.xcresult`, Archives, logs, and credentials remain untracked.
4. Run `./script/phase_gate.sh SM-XX` on the clean review commit.
5. Copy the concise results into `reviews/SM-XX.md`, including exact commands,
   commit SHA, toolchain, scope audit, and unresolved findings.
6. The Repository Owner records approval. Set `CURRENT_STATE.json` to COMPLETE
   only when no blockers remain. Commit the approval using only the state file
   and phase review; no source change may share that approval commit.

The Gate never edits tracked state, approves a phase, commits files, or starts
the next phase.

## Environment blocks and equivalent evidence

Equivalent evidence is accepted only when a local check is `BLOCKED_ENV`, the
phase and review commit match, and the evidence entry reports `PASS`.

- Critical checks require a CI run or qualified Mac, the exact command, a
  durable artifact/run reference, and a timestamp.
- Owner waivers are forbidden for compilation, core tests, data isolation,
  compatibility contracts, and real App launch.
- A non-critical Owner waiver requires owner, reason, expiry, and the latest
  phase by which the check must be rerun.
- A real `FAIL` can never be converted to PASS by external evidence.

Use `--evidence <file>` with the schema in
`reviews/EQUIVALENT_EVIDENCE.template.json`. SM-02 will make macOS CI invoke
this same Gate; CI must not create a second set of phase rules.

## Evidence retention

Local runs are stored under `.codex/gate-results/` and ignored by Git. CI may
retain the same directory as a run artifact. The repository commits only the
short review report, Gate policy, phase package, and state record.

The premium UI report is regenerated from `premium-ui.json`. A phase report
records the exact audit command and finding count; ignored `premium-audit.json`
is not the sole authority.

## Findings outside the active phase

A valid finding outside the active phase is recorded in the owning future
package with severity, evidence, and intended Gate. It does not block the
current phase unless it invalidates a current compatibility or safety contract.
Known SQLite row-step error handling belongs to SM-04.
