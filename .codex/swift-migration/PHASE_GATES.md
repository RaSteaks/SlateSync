# SlateSync phase admission policy

This policy is authoritative for SM-00 through SM-09. A phase implementation
and a phase admission are separate events: passing tests does not update state,
and editing `CURRENT_STATE.json` does not manufacture evidence.

## Current SM-09 acceptance scope

The Owner's 2026-10-27 scope revision is defined in
[acceptance policy v2](../../docs/sm09-acceptance-policy.md). For SM-09, a clean
functional Gate with completionEligible=true can support completion review:
native migration, functionality, data compatibility, resource safety and the
local Universal Archive/ZIP/DMG must pass. Timing and FPS are advisory for this
milestone. Default full Gate performance and distribution requirements remain strict.

The existing approvable field retains its full-Gate meaning; functional results
remain approvable=false and fullAcceptancePassed=false. completionEligible is
eligibility for review, never automatic Owner approval. Older reports without
the new policy fields do not automatically become v2 completion evidence.
This scope rule supersedes only conflicting SM-09 completion requirements below;
historical approvals, required functional tests and evidence integrity remain intact.

## Lifecycle

`NOT_STARTED → IN_PROGRESS → REVIEW_READY → PASS | BLOCKED → COMPLETE`

- `REVIEW_READY` means the implementation is frozen in a dedicated commit or PR.
  Its same-phase Gate may run before PASS exists; approval freshness is
  `NOT_APPLICABLE` until COMPLETE. REVIEW_READY never admits a successor phase.
  Reopening an approved phase archives the old approval and verification, clears
  current approval fields, and requires a new exact-commit Gate and Owner approval.
- `PASS` means every required Gate check in the recorded acceptance scope passed
  for that exact commit.
- `BLOCKED` means at least one required check is `FAIL` or unresolved
  `BLOCKED_ENV`.
- `COMPLETE` requires `PASS`, an evidence report, and Repository Owner approval.
  SM-09 policy v2 accepts functional-and-local-package completion evidence; it
  does not certify full performance or a distribution channel.
- The next phase may become `IN_PROGRESS` only after the current phase is
  `COMPLETE`.
- `PASS` is a legal recorded intermediate state (CARRY-09 governance
  decision, 2026-09-07): recording approval necessarily creates a new commit,
  so `CURRENT_STATE.json` may report `lifecycleState: PASS` for the reviewed
  phase while Owner approval is pending. During that window a Gate rerun for
  the same phase stays valid and `approval_freshness` is `NOT_APPLICABLE`
  until approval is recorded; CI resolves the Gate to the state phase itself.
  Pre-admission of the next phase (state phase = requested phase − 1) still
  requires `COMPLETE` and never accepts `PASS`.

Rewriting history or adding product/source changes after review makes approval
stale. Because recording tracked approval metadata necessarily creates a new
commit, HEAD may follow the reviewed commit only when the complete diff is
limited to `CURRENT_STATE.json` and that phase's review report. Any other path
requires a new Gate run and Owner approval.

## Check results and exit codes

Checks use `PASS`, `FAIL`, `BLOCKED_ENV`, `NOT_APPLICABLE`, and `NOT_RUN`.

- `PASS`: the command ran and its assertions succeeded.
- `FAIL`: product code, contracts, tests, or artifacts are wrong. Evidence and
  Owner approval cannot replace it.
- `BLOCKED_ENV`: an external execution condition prevented a result, such as
  cache sandboxing, an unavailable GUI session, Xcode licensing, or credentials.
- `NOT_APPLICABLE`: the package declared the check irrelevant before review.
- `NOT_RUN`: a prerequisite prevented execution; this is not a passing result.

`phase_gate.sh` exits `0` for a clean functional PASS or an approvable clean full
PASS, `1` for FAIL, `2` for BLOCKED_ENV, `3` for a successful `--allow-dirty`
diagnostic run, and `64` for invalid usage or an unknown phase. The scope and
completionEligible/fullAcceptancePassed fields, not exit zero alone, determine
which review the evidence can support.

## Required workflow

1. Implement only the active phase and update its package.
2. Iterate with focused tests, builds and `./script/ci_preflight.sh` locally.
   Full Gate/UI/foreground performance runs belong on the GitHub macOS runner;
   local foreground execution requires explicit scheduling by the Owner.
   A `--allow-dirty` diagnostic is never completion or release acceptance.
3. Create a dedicated phase commit or PR. Generated results, DerivedData,
   `.xcresult`, Archives, logs, and credentials remain untracked.
4. For current SM-09 completion, run `./script/phase_gate.sh SM-09 --functional`
   on the clean review commit in the remote runner. Full release acceptance uses
   the same command without `--functional`. Historical phase Gates run only at
   their recorded historical commits.
5. Copy the concise results into `reviews/SM-XX.md`, including exact commands,
   commit SHA, toolchain, scope audit, and unresolved findings. Policy v2 records
   performance failures separately with their follow-up; they are not PASS.
6. The Repository Owner records approval. Set `CURRENT_STATE.json` to COMPLETE
   only when no blockers within the declared completion scope remain. Commit
   the approval using only the state file and phase review; no source change
   may share that approval commit.

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

For the current workspace, new local test/log/temp/build artifacts belong under
`${SLATESYNC_VALIDATION_ROOT}`, with explicit temporary/cache/output
paths. Remote CI uses its isolated runner artifact root; downloaded copies go
under that local directory. Existing historical paths are not rewritten.
The repository commits only the short review report, Gate policy, phase package,
and state record, not generated evidence.

The premium UI report is regenerated from `premium-ui.json`. A phase report
records the exact audit command and finding count; ignored `premium-audit.json`
is not the sole authority.

## Findings outside the active phase

A valid finding outside the active phase is recorded in the owning future
package with severity, evidence, and intended Gate. It does not block the
current phase unless it invalidates a current compatibility or safety contract.
Known SQLite row-step error handling belongs to SM-04.
