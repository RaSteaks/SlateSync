# SM-XX phase review

- Lifecycle state: `REVIEW_READY`
- Review commit: `<40-character Git SHA>`
- Branch/PR: `<branch or PR URL>`
- Toolchain: `<Xcode / build / Swift / SDK>`
- Gate command: `./script/phase_gate.sh SM-XX`
- Gate result: `<PASS | FAIL | BLOCKED_ENV>`
- Local result path: `<untracked .codex/gate-results path or CI artifact>`

## Check summary

| Check | Critical | Result | Evidence |
| --- | --- | --- | --- |
| Common build/test/scope checks | Yes | `<result>` | `<command or artifact>` |
| Phase-specific compatibility checks | Yes | `<result>` | `<command or artifact>` |
| Non-critical audits | No | `<result>` | `<command, finding count, or waiver>` |

## Scope and findings

- In-scope changes: `<summary>`
- Out-of-scope diff: `<none or exact paths and disposition>`
- Compatibility impact: `<none or contract reference>`
- Data isolation: `<temporary roots and confirmation>`
- Tracked future findings: `<none or package references>`
- Blocking findings: `<none or actionable list>`

## Environment substitutions

Record each `BLOCKED_ENV` check, equivalent-evidence file, source run, matching
commit, and why the source environment is equivalent. Write `None` when unused.

## Owner decision

- Decision: `<APPROVED | REJECTED | PENDING>`
- Owner: `<name>`
- Approved at: `<ISO-8601 timestamp>`
- Review commit rechecked against HEAD: `<yes | no>`
- Non-critical exception expiry/revalidation: `<none or exact deadline>`

Approval is invalid when any critical check is unexecuted, Gate is not PASS,
the worktree is dirty, or blocking findings remain. HEAD must equal the review
commit or differ only by a committed Owner decision in `CURRENT_STATE.json` and
this phase review; any source/product change invalidates approval.
