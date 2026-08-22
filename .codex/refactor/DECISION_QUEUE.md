# Decision Queue

## Current resolution index — 2026-08-22

Authority source: `README.md`, `CURRENT_STATE.json`,
`reviews/GATE-01-02.md`, and `packages/IP-03-08-CONTINUOUS.md` version
`2026-08-21.2`.

This queue is append-only evidence. Earlier `OPEN`, `BLOCKED`, or `WAITING
REVIEWER CLOSE` text records the state at that point in time and must not be
treated as a current blocker after a later disposition below.

| Decision | Current disposition |
| --- | --- |
| `IP-00-BUILD-001` | CLOSED for refactor Gates; unsigned directory build accepted. |
| `IP-00-VISUAL-001` | CLOSED for the real legacy ten-state baseline. |
| `IP-0102-VISUAL-001` | CLOSED for Gate 01-02; modern visual evidence belongs to the continuous package. |
| `IP-0102-ELECTRON-001` | CLOSED by production and packaged smoke. |
| `IP-0102-BASELINE-001` | CLOSED by exact contracts and green aggregate validation. |
| `IP-0102-PRELOAD-001` | ACCEPTED AND CLOSED by Gate 01-02. |
| `IP-03-08-DATABASE-ABI-001` | ACCEPTED, NON-BLOCKING; keep `better-sqlite3` and automated ABI lifecycle. |
| `IP-03-08-SAFETY-ISOLATION-001` | OWNER ACCEPTED — CLOSED; historical row-level impact remains unprovable, path stays quarantined, and no content access or cleanup is authorized. |
| `IP-03-08-CONTINUOUS-CLEANUP-001` | ACCEPTED FOR THIS RUN — NO DELETIONS; C02 reverified. |
| `IP-03-08-REPO-HYGIENE-001` | OWNER AUTHORIZED — STANDALONE `.gitignore` hygiene only; no production or evidence-scope expansion. |
| `IP-03-08-C01-STOP-001` | RESOLVED FOR HANDOFF — verifier reconciled for both legal phases; waiting for Sol Final Review. |
| `IP-03-08-C02-TECHNICAL-001` | RESOLVED — task/CSV/preparation/scope/performance/visual/package findings corrected and validated. |
| `IP-03-08-C02-SCOPE-001` | RESOLVED BY OWNER-DIRECT FINDING CLOSURE — no-op Project Library control removed; `.gitignore` churn reverted; no general scope expansion. |

Current blocking decisions: **none**. All technical C02 findings and the C03
safety disposition are resolved. Historical `OPEN` text remains evidence, not
current status; the accepted data uncertainty is disclosed and the quarantined
path remains outside all future automated operations.

## Decision ID: IP-03-08-REPO-HYGIENE-001

Owner authorization (2026-08-22) permits the root `.gitignore` update as a
standalone repository-hygiene change. Its sole purpose is to keep local
environment variants, reproducible build/test output, and redundant visual
captures out of future commits. Required baseline/final evidence remains
visible, and the quarantined Project Library remains inaccessible.

The exact authorization, protected scope, stop conditions, and acceptance
evidence are recorded in
`.codex/refactor/evidence/IP-03-08/final-handoff/GITIGNORE-HYGIENE-AUTHORIZATION.md`.
The scope verifier attributes `.gitignore` to a dedicated `hygiene` bucket;
this does not authorize production changes or a wildcard scope exception.

Status: **RESOLVED — OWNER AUTHORIZED STANDALONE HYGIENE CHANGE**.

## Decision ID: IP-03-08-C01-STOP-001

Context: C01 requires `CURRENT_STATE.json.phase` to become
`IP-03-08_READY_FOR_FINAL_REVIEW` and requires the existing
`verify-current-state.mjs` to pass again after that change.

Observed conflict: The existing verifier strictly asserts
`IP-03-08_READY_FOR_CONTINUOUS_IMPLEMENTATION`. C01 does not authorize the
verifier path, and its Stop Conditions prohibit expanding the correction
scope. The required final phase therefore makes the required final verifier
fail.

Evidence: `.codex/refactor/evidence/IP-03-08/final-handoff/C01-STOP-001.md`.

Required resolution: Sol/owner must authorize a minimal verifier/authority
reconciliation or publish a corrected C01 package with consistent Allowed
Scope and acceptance requirements. No temporary state, duplicate JSON key,
test bypass, or protected-script edit is permitted.

Status: **BLOCKING — C01 HANDOFF STOPPED; FINAL REVIEW NOT ADMITTED**.

## Resolution record: IP-03-08-C01-STOP-001 — 2026-08-21

Owner-directed continuation applied the minimal governance reconciliation
required by the C01 objective. `verify-current-state.mjs` now accepts the
documented implementation and final-review phases and requires the exact
Completion Report path in the latter phase. The exact scope verifier now
recognizes the C01-authorized root `AGENT.md` and `AGENTS.md` records. The
production implementation, test assertions, fixtures, lockfile, package
configuration, and data contracts were not changed by this reconciliation.

The full C01 acceptance matrix then passed, the standalone Completion Report
was written, and `CURRENT_STATE.json`/`README.md` were reconciled. This record
does not close the refactor or either safety/cleanup decision on Sol's behalf.

Status: **RESOLVED FOR HANDOFF — WAITING SOL FINAL REVIEW**.

## Decision ID: IP-00-VISUAL-001

Context: IP-00 requires ten deterministic 1440×900 screenshots captured by a test-only Electron preload/harness while loading the unchanged `public/index.html` and Renderer.

Observed conflict: On the current macOS execution environment, Electron 43.3.0 cannot reach a usable BrowserWindow for the isolated harness. A normal launch exited with `SIGABRT`; an escalated offscreen/headless launch remained alive for 30 seconds without producing a capture and was terminated by the bounded timeout. No screenshot or manifest file was produced. The existing application and production files were not modified.

Current contract: Visual baselines must represent the actual current Renderer and must not be replaced with generated placeholders, production hooks, arbitrary sleeps, skipped tests, or cross-platform assumptions. IP-00 Stop Conditions 9 and 11 require stopping the affected visual subtask when capture needs unavailable GUI/toolchain state.

Option A: Run `test-support/baseline/capture-visuals.mjs` on a macOS desktop session with Electron 43.3.0 GUI/offscreen support, then commit the ten PNGs and manifest after two stable captures.

Option B: Sol authorizes a separate platform-specific visual-capture package that defines a supported headless renderer and acceptance evidence, without changing production UI code or weakening the IP-00 visual test.

Recommendation: Option A. Keep IP-00 visual status blocked until a real Electron desktop/offscreen session is available; do not fabricate images or mark Gate 00 approved.

Affected modules: `test-support/baseline/capture-visuals.mjs`, `test/baseline-visual.test.mjs`, `.codex/refactor/baseline/visual/**`.

Blocking: yes (visual subtask only; recognition, CSV, persistence, contract, scope, and documentation baselines may proceed).

Architect/Owner disposition (2026-08-18): **DEFERRED WITH EXPIRY**. The original recommendation and Gate-00 blocking classification are superseded by the corrected runtime observation and Owner's batching decision. The missing visual evidence is non-blocking only for Gate 00 and implementation of non-UI Batch 01-02. It remains a blocking, enabled acceptance test for Joint Gate 01-02 and must be resolved before IP-03. Batch 01-02 receives only the path-exact carryover scope listed in `packages/IP-01——IP-08.md`; placeholders, mocks presented as captures, production UI changes, skipped tests, or relaxed assertions remain forbidden.

C01 observation (2026-08-18): The corrected harness now uses a fresh OS
temporary `userData` and preload, fresh BrowserWindow per state, asserted
1440×900 content viewport, explicit route/state/font readiness, synthetic
multi-page input, and complete stability metadata. It still cannot execute on
this host: the installed Electron.app fails `codesign --verify --deep --strict`
with `code has no resources but signature indicates they must be present`; a
normal launch aborts, and an escalated minimal `app.whenReady()` probe never
executes application code. Experiments against disposable copied bundles were
removed and did not alter `node_modules` or production files. Option A and the
blocking status remain unchanged.

## Decision ID: IP-00-BUILD-001

Context: IP-00-C01 requires the exact `npm run electron:build:dir` command,
without substituting an unsigned or otherwise altered build command.

Observed conflict: The sandboxed run reached packaging but could not resolve
`github.com`. The approved network run downloaded and extracted Electron,
rebuilt `better-sqlite3`, and reached macOS distribution signing with identity
`Apple Development: 8613857405876 (C9GM69F8R9)`, then produced no further
output for 60 seconds. It was terminated with `SIGINT` rather than allowed to
wait indefinitely for external Keychain/signing UI. The exact command did not
pass; no altered unsigned command is claimed as equivalent.

Current contract: Build identity, entitlements, signing behavior, and the exact
acceptance command are protected. IP-00-C01 Stop Condition 11 requires stopping
the build subtask when an external signing/toolchain limitation prevents the
exact command from completing.

Option A: Run the exact command in an interactive macOS session where the
selected signing identity has non-interactive Keychain access, then retain its
zero exit status.

Option B: Architect authorizes a separate build-validation package that defines
an unsigned directory-build command; this cannot be retroactively reported as
the IP-00 exact command.

Recommendation: Option A. Keep Gate 00 blocked until the exact command exits
successfully.

Affected modules: packaging validation evidence only; no production source or
configuration change is requested.

Blocking: yes (build-validation subtask).

Architect/Owner disposition (2026-08-18): **RESOLVED FOR REFACTOR GATES**. Apple Development signing is not required in the current refactor because the Owner has no signing key and does not require a signed app now. The local acceptance command is `CSC_IDENTITY_AUTO_DISCOVERY=false npm run electron:build:dir`; it completed successfully on 2026-08-18 after network access was available. Existing signing, entitlements, notarization, publishing, and release configuration remains Protected Scope. Signing becomes a Gate only if the Owner later starts a separate release-preparation review.

## Observation correction: IP-00-VISUAL-001

Owner-provided startup path: From the repository root, `npm start dev` runs
`preelectron:dev`, successfully rebuilds `better-sqlite3`, and launches
`electron electron/main.mjs dev`. This current development application remains
running and does not reproduce the earlier `SIGABRT`. Therefore the installed
application/runtime must not be described as generally unable to start, and
Apple distribution signing is unrelated to visual capture.

The remaining visual issue is narrower: the test-only
`capture-visuals.mjs` independent main process loads but does not reach
`app.whenReady()`/the first capture marker in the same environment. It cannot
yet produce the ten isolated synthetic states. This observation supersedes the
earlier diagnosis of a generally unusable Electron host, but does not fabricate
or resolve the missing PNG/manifest evidence.

Blocking: yes (test harness integration only, pending an Architect-approved
capture path that reuses the current development lifecycle).

Architect update (2026-08-18): The approved resolution window is Batch 01-02. Gate 00 is no longer blocked, but Joint Gate 01-02 and every UI batch remain blocked until the real PNG/manifest evidence exists and the unchanged visual test passes.

Owner policy update (2026-08-20): **DEFERRED TO UNIFIED POST-UI VALIDATION; NON-BLOCKING FOR PRE-UI WORK**. The real, stable PNG/manifest evidence and unchanged visual test remain mandatory and may not be weakened or fabricated. The expiry moves from Joint Gate 01-02 to the Continuous Completion Report for `IP-03-08-CONTINUOUS.md`, after the modern UI is integrated. This debt alone no longer blocks non-UI IP-01/02 completion, Gate 01-02 approval, or pre-UI continuous architecture work; it blocks readiness for Sol Final Review.

## Decision ID: IP-0102-ELECTRON-001

Context: IP-01 requires the bounded Electron smoke command to prove default
legacy startup, opt-in modern startup, and safe fallback. The command must
remain a real Electron launch; skipping it, replacing it with a pure unit
test, or weakening its assertions is not authorized.

Observed conflict: `npm run test:electron:smoke` launched the installed
Electron 43.3.0 binary but the child terminated with `SIGABRT` before the
smoke marker was emitted (exit code 99). A separately bounded `npm start dev`
run rebuilt the native module and logged `Loaded legacy renderer`, then the
Electron process terminated with the same signal. The Owner-provided macOS
15.7.3 ARM64 crash report identifies Thread 0 aborting in AppKit/HIServices
`_RegisterApplication` during `NSApplication` initialization. No modern
smoke assertion or package-content assertion can be completed from this
runtime evidence.

Current contract: Electron 43.3.0, the legacy default, the development-only
modern selector, one Renderer per window, bounded smoke execution, and the
existing visual test are all required. The IP-01 Stop Conditions require
stopping the entire batch for a new non-visual failure. No application code,
IPC surface, data format, security flag, or test assertion may be changed to
hide a host-level Electron/AppKit abort.

Option A: Re-run the unchanged smoke and startup commands in a supported
macOS GUI session or repaired Electron 43.3.0 installation, retaining the
same Node/Electron versions and all existing assertions; preserve the crash
report and successful output as evidence.

Option B: Sol authorizes a separate platform-specific Electron validation
package that defines an approved runtime/test adapter without weakening the
IP-01 smoke contract or changing production startup behavior.

Recommendation: Option A. Treat this as an external Electron/AppKit runtime
blocker, not an implementation defect to be worked around in `electron/main.mjs`.
The existing visual carryover (`IP-00-VISUAL-001`) remains independently
unresolved and cannot be claimed complete from this failed launch.

Affected modules: `test-support/refactor/electron-smoke.mjs`, validation
evidence under `.codex/refactor/evidence/IP-01/**`, and the IP-01 batch
handoff. No Protected Scope module is changed by this decision.

Blocking: yes (entire IP-01 + IP-02 batch).

Status (2026-08-20): **OPEN — BATCH STOPPED**. IP-01 non-Electron checks
completed before this Stop Condition: `npm run typecheck`,
`npm run test:modern`, and `npm run build:modern` passed. The remaining
acceptance commands, IP-02 implementation, and batch handoff are not claimed
complete.

## Decision ID: IP-0102-BASELINE-001

Context: The IP-01 aggregate test command must retain every Gate-00 assertion
while adding the approved build transition. It may not delete, relax, or
auto-update baseline facts.

Observed conflict: After the authorized IP-01 build/selector changes,
`npm test` completed the legacy Node suite with 223 passes and 4 failures,
with zero skipped/todo tests. Two failures are the existing baseline contract
tests that still assert the pre-transition package scripts and exact
`join(allowedDir, "index.html")` source shape; IP-01 permits an additive
contract/test adaptation, but that adaptation was not started before the
Electron smoke Stop Condition. The visual manifest failure remains the
pre-approved `ENOENT` carryover. The fourth failure is the new
`test/refactor/ip-01/skeleton.test.ts` being discovered by this host's Node
24.13.0 `node --test` invocation and failing its extensionless ESM import;
the same skeleton passes when run by the standalone Vitest command.

Current contract: Baseline assertions must remain effective, the modern test
must run in the designated Vitest suite, and no test may be skipped or
weakened. The IP-0102 batch is already stopped by `IP-0102-ELECTRON-001`, so
no contract adaptation or test-runner workaround is authorized in this
blocked turn.

Resolution required: In a resumed, Architect-authorized correction, append
the exact IP-01 transition facts to `build.json` and the baseline contract
test, and make the Node/Vitest test boundaries deterministic for the
supported Node 22 CI runtime without reducing coverage. Re-run the complete
acceptance sequence afterward.

Affected modules: `.codex/refactor/baseline/contracts/build.json`,
`test/baseline-contracts.test.mjs`, `package.json` test-runner wiring, and
`test/refactor/ip-01/skeleton.test.ts`. No Protected Scope module is changed
by this decision.

Blocking: yes (batch remains stopped; this entry is subordinate to
`IP-0102-ELECTRON-001`).

Status (2026-08-20): **OPEN — NOT FIXED IN BLOCKED TURN**.

## Decision ID: IP-0102-VISUAL-001

Context: The approved Gate-00 visual repair keeps the unchanged
`test/baseline-visual.test.mjs` contract and requires the exact Electron
capture command to produce ten isolated 1440×900 legacy Renderer PNGs twice
with identical dimensions and SHA-256 values.

Observed conflict: The capture harness was updated within its path-exact scope
to use a normal hidden BrowserWindow, non-persistent per-state sessions,
bounded lifecycle diagnostics, OS-temporary staging, and manifest-last
publication. The exact command was then run both directly and from the current
user's macOS Terminal desktop session. Both executions loaded the harness and
printed `waiting for Electron app readiness`, but `app.whenReady()` did not
resolve within the 15-second watchdog. No BrowserWindow, PNG, manifest, or
partial staged output survived cleanup.

Current contract: The visual test remains byte-identical. Production UI, IPC,
data formats, dependencies, real userData, and signing configuration are
protected. A second capture, LaunchServices fallback, production hook,
placeholder, arbitrary readiness sleep, relaxed assertion, or automatic
golden acceptance is forbidden after this Stop Condition without new
Architect authorization.

Option A: Diagnose why Electron 43.3.0 does not deliver `ready` for an
independent main script in this macOS desktop session, then rerun the unchanged
command twice after the runtime condition is corrected.

Option B: Architect explicitly authorizes a separate macOS LaunchServices
capture adapter and the corresponding exact-command contract update while
preserving the same real Renderer, isolation, dimensions, hashes, and unchanged
visual assertions.

Recommendation: Option A. The cached Electron archive SHA-256 matches the
package's exact checksum, and Apple signing is outside this refactor, so do not
re-sign Electron or change production/package configuration as a workaround.

Affected modules: `test-support/baseline/capture-visuals.mjs`,
`.codex/refactor/baseline/visual/**`, and
`.codex/refactor/evidence/IP-00/visual/**`.

Blocking: yes for completing the Gate-00 legacy visual repair and for final
unified visual evidence. Under the Owner's 2026-08-20 policy, this visual debt
alone does not block non-UI IP-01/02 or non-UI continuous work.

Status (2026-08-20): **OPEN — WAITING FOR REVIEWER DECISION**. Exact failure
output and integrity facts are retained in
`.codex/refactor/evidence/IP-00/visual/terminal-capture-failure.md`.

Implementation evidence update (2026-08-20): The readiness deadlock was traced
to top-level-awaiting `app.whenReady()` in the independent Electron ESM main
script; scheduling capture from the ready promise restored the normal lifecycle.
The remaining single-state mismatch was traced to capturing an intermediate
frame of the production smooth scroll to the results section. Readiness now
requires the root scroll position to remain unchanged across consecutive
animation frames. The exact command completed twice in 1745 ms and 1702 ms;
all ten 1440×900 dimensions and SHA-256 hashes are identical. The unchanged
visual test, scope hashes, and full-suite results remain the required final
checks. Evidence: `.codex/refactor/evidence/IP-00/visual/comparison.json`,
`run-1-manifest.json`, and `run-2-manifest.json`. Status remains **OPEN —
WAITING FOR REVIEWER CLOSE**; the Implementer does not close the decision.

Post-capture validation update (2026-08-20):
`node --test test/baseline-visual.test.mjs` passed 1/1 with no skip, todo, or
modified assertion. In the full `npm test` run the same visual test passed;
the run ended at 224/227 because of three already-existing, non-visual IP-0102
failures: package/build inventory drift, Electron source-contract drift, and
Node's native runner collecting `test/refactor/ip-01/skeleton.test.ts` without
TypeScript module resolution. `npm run test:modern` passed 2/2. These failures
are outside this visual package's Allowed Scope and were not hidden or relaxed.

## IP-0102 implementation evidence update — 2026-08-20

The batch resumed under the existing package authority. The previously open
non-visual findings are corrected in their allowed paths:

- `IP-0102-ELECTRON-001`: the smoke harness now gives each legacy/modern page a
  fresh Electron child and one hidden window, preserving the bounded real GUI
  assertion. In the current macOS desktop session,
  `npm run test:electron:smoke` passed with both the default legacy and
  opt-in modern markers. The old host abort is superseded by this successful
  evidence; status is **RESOLVED FOR IMPLEMENTATION — WAITING REVIEWER CLOSE**.
- `IP-0102-BASELINE-001`: the additive build/IPC transition assertions and
  deterministic Node/Vitest boundary are active. `npm run test:node` passed
  227/227, `npm run test:modern` passed 7/7, and `npm test` passed both suites;
  status is **RESOLVED FOR IMPLEMENTATION — WAITING REVIEWER CLOSE**.
- `IP-0102-VISUAL-001`: the exact capture command completed twice in the
  current desktop session. The final manifest records ten 1440×900 captures,
  `verifiedAgainstPreviousRun: true`, `identicalCaptureCount: 10`, and 1.9 MiB
  total PNG bytes; the unchanged visual test passed 1/1. The evidence is
  complete, but the Implementer leaves the decision **WAITING REVIEWER CLOSE**.

The lockfile was regenerated only to reconcile the authorized modern
dependencies; `npm ci` now passes. No production business module, Main
handler, data format, security flag, signing setting, or protected UI path was
changed. No new architecture deviation or blocking decision was introduced by
this batch; Sol/Reviewer still owns closure and Shared Contract v1 freeze.

## IP-0102-C01 implementation evidence update — 2026-08-20

The authorized correction replaces the prior self-authored smoke with the
production composition root. Default legacy, opt-in modern, missing modern,
failed modern load, and the unsigned packaged executable all passed using
temporary profiles and Project Libraries. The smoke proves one Renderer,
exact file roots, denied navigation/windows, six typed namespaces, no
`electronAPI`/generic invoke/Node globals, native SQLite, pdf.js, and automatic
Node ABI restoration after Electron runs. Five production runs per mode record
legacy median 169.4 ms and modern median 164.5 ms. Evidence is under
`.codex/refactor/evidence/IP-01/`.

Shared Contract v1 now distinguishes scenario summaries/full profiles,
project summaries/details, library action results, live/persisted recognition
records, exact scanner stats/metadata, CSV format/table/edit snapshots, and
legacy usage variants. The sole production adapter reads only `slateSync`.
All 27 operations have exact DTO/parity fixtures; error, listener, binary, and
destroyed-sender matrices are executable. The latest Node suite passes 229/229
and modern suite passes 6/6 with no skip/todo/only. Root `.tsbuildinfo` and
source-tree compiler outputs were removed; exact scope modes pass separately.

`IP-0102-ELECTRON-001`, `IP-0102-BASELINE-001`, and
`IP-0102-VISUAL-001` are now **RESOLVED FOR IMPLEMENTATION — WAITING REVIEWER
CLOSE**. The Implementer does not close these decisions.

## Decision ID: IP-0102-PRELOAD-001

Context: C01 requested production typed Preload evidence while preserving
`sandbox: true`. The first production run loaded the correct repository page
but Electron 43 rejected `electron/preload.cjs` calling
`require("../out/preload/index.cjs")`; sandbox preload `require` cannot load an
application-local second module.

Decision implemented: BrowserWindow now loads the one compiled typed CommonJS
entry `out/preload/index.cjs` directly. That entry self-activates only when
`process.versions.electron` exists, so Node contract/benchmark imports remain
side-effect free. `electron/preload.cjs` is a non-executable transition marker.
No sandbox/security flag, public gateway, raw channel, Main handler, data
format, dependency, or production test hook changed, and no bridge logic was
duplicated.

Evidence: `.codex/refactor/evidence/IP-01/production-smoke.json`,
`packaged-smoke.json`, the updated executable baseline contract, and the asar
content list. Actual rejected-`invoke` serialization facts are in
`.codex/refactor/evidence/IP-02/electron-rejected-invoke.json`.

Blocking: no implementation work remains; Gate 01-02 Reviewer must accept or
reject this security-preserving compiled-entry decision.

Status: **IMPLEMENTED — WAITING REVIEWER CLOSE**.

## Reviewer resolution: GATE-01-02 — 2026-08-21

Sol High independently reviewed and reran the corrected foundation. Verdict:
**APPROVED**.

- `IP-00-BUILD-001`: closed for refactor Gates; unsigned directory validation
  remains the accepted local policy and signing/release settings stay protected.
- `IP-00-VISUAL-001` and `IP-0102-VISUAL-001`: closed for the genuine legacy
  ten-state baseline; the modern unified baseline remains a continuous-package
  final deliverable rather than an open legacy blocker.
- `IP-0102-ELECTRON-001`: closed by production GUI-session and unsigned
  packaged smoke.
- `IP-0102-BASELINE-001`: closed by exact contracts, green baseline/aggregate
  suites, deterministic scopes, and final native-runtime restoration.
- `IP-0102-PRELOAD-001`: accepted and closed. Directly loading the one compiled
  CommonJS Preload is the approved sandbox-preserving path; the historical
  marker is non-executable and not a second gateway.

There is no blocking IP-0102 decision. The sole downstream authority is
`packages/IP-03-08-CONTINUOUS.md`, followed by one Sol High Final Review.

## Decision ID: IP-03-08-DATABASE-ABI-001

Context: system Node tests and Electron development/package execution load the
same `better-sqlite3` installation under different native ABIs. Rebuilding the
shared binary for one runtime invalidates it for the other until restored.

Observed conflict: repeated manual switching is error-prone and was previously
mistaken for a removed Node Web-server dependency. Replacing the database to
avoid this inconvenience would touch the most protected persistence surface
during the continuous UI/ownership refactor.

Current contract: Main owns SQLite and must preserve existing database files,
schema, WAL/foreign-key/busy-timeout behavior, transactions, backups,
migrations, paths, file modes, and Project Library/task semantics.

Option A: keep `better-sqlite3`, automate both runtime preparations and prove
Electron-to-Node restoration in development, CI, and release validation.

Option B: replace it with `node:sqlite` after a separate post-refactor
differential/migration/performance package proves parity on copied data.

Option C: use `sqlite3`, a query builder, or WASM/OPFS during IP-03-08.

Recommendation and decision: Option A for IP-03-08; retain Option B as a
future isolated evaluation. Reject Option C because it either retains native
ABI requirements or changes ownership/filesystem/locking semantics while
adding migration risk. Details and acceptance criteria are in
`adr/ADR-DATABASE-RUNTIME-ABI.md`.

Affected modules: current package/CI validation only. No production database,
schema, data format, ownership, or user path changes.

Blocking: no. This is the approved continuous-package database boundary. A
driver change inside IP-03-08 would create a new blocking Stop Condition.

Status: **ACCEPTED — AUTOMATED LIFECYCLE; DRIVER MIGRATION DEFERRED**.

## Decision ID: IP-03-08-SAFETY-ISOLATION-001

Context: The first Electron E2E and visual-capture attempts used temporary
`--user-data-dir` directories without writing a temporary machine
`settings.json` with an isolated `libraryPath`. On macOS, `appData` remains
the OS application-data root, and SlateSync derives its default Project
Library from that root when `libraryPath` is empty.

Observed risk: The default library path exists. The affected attempts opened
the real composition root; one E2E case created a synthetic project to exercise
the CSV Worker, and one visual attempt created a synthetic project before a
selector assertion stopped the capture. It is therefore not provable from
the current evidence that no user Library record was touched.

Containment already implemented: both E2E and visual launchers now seed
`settings.json` before Electron startup, pointing inside their temporary
profile. The contained rerun was not started after this discovery. No direct
SQLite mutation, deletion, reset, or archive cleanup was attempted. The Node
native ABI was restored. Full facts are in
`.codex/refactor/evidence/IP-03-08/E2E-ISOLATION-INCIDENT.md`.

Required decision: Sol/user must authorize an owner-approved audit/restoration
procedure, or explicitly confirm that the default Library was not an active
user Library. Until then, no further Electron, E2E, visual, migration,
packaging, or Library operation may run. Continuing would compound an
unresolved data-safety boundary and violate the package prohibition on using
an active Project Library.

Status: **BLOCKING — CONTINUOUS IMPLEMENTATION STOPPED**.

## Disposition record: IP-03-08-SAFETY-ISOLATION-001 — 2026-08-21

The owner-directed, non-invasive path-level impact audit is recorded in
`.codex/refactor/evidence/IP-03-08/LIBRARY-IMPACT-AUDIT.md`. It confirmed that
the default macOS Library path was created during the affected run window and
that its SQLite file was modified during that window, but it intentionally did
not open, hash, copy, migrate, restore, archive, delete, or rewrite any
Library content. This leaves row-level attribution unprovable, so the default
path is quarantined for the remainder of the task and is not a valid test or
migration source.

The containment disposition permits only newly created temporary profiles and
explicit temporary `libraryPath` values for the remaining validation. The
original safety decision remains visible for Sol's independent review; no
claim is made that the default Library's contents are unchanged. Any
owner-visible restoration or content-level review remains outside this
non-invasive audit.

Status: **AUDITED — QUARANTINED; ISOLATED VALIDATION MAY CONTINUE**.

## Decision ID: IP-03-08-CONTINUOUS-CLEANUP-001

Context: Workstream 9 requires a path/symbol-exact cleanup manifest before
any deletion. The integrated implementation still references the legacy
renderer adapter, bounded recovery root, version-1 migration readers,
compatibility fixtures, PDF/Worker resources, native package resources,
baseline tests, and visual/package evidence. The default macOS Project
Library is also quarantined and is not a cleanup source.

Decision: Apply the owner-authorized manifest-limited rule in
.codex/refactor/CONTINUOUS_CLEANUP_MANIFEST.md. The exact deletion and
replacement sets for this continuous run are empty. All audited candidates
are retained with path/symbol-specific reasons and rollback effects. No
wildcard, name-based, generated-output, legacy-name, dependency, route, IPC,
style, asset, test, or comment deletion is authorized by this entry.

Evidence: The manifest, pre-cleanup reference audit, orphan audit, final
acceptance matrix, and package scope verifier are recorded under
.codex/refactor/evidence/IP-03-08/.

Blocking rule: This is non-blocking only for the recorded no-op cleanup.
Any later deletion, live reference, migration/data dependency, ambiguity,
unexpected lockfile churn, or scope expansion is a Stop Condition and
requires a new exact manifest entry.

Status: **ACCEPTED FOR THIS RUN — NO DELETIONS; WAITING SOL FINAL REVIEW**.

## Resolution record: IP-03-08-C02-TECHNICAL-001 — 2026-08-22

The C02 correction restored atomic task projection/Worker priming, serialized
autosave ownership, project/task actions, slate CSV Worker workflows, canonical
material-key ownership, full preparation/PDF parity, resource cleanup and
package-sensitive scope verification. The unauthorized `.gitignore` change was
reverted. Final aggregate tests are Node 232/232 and modern 8 files/19 tests;
Electron E2E is 10/10; the final visual pair is 14/14 byte-identical; unsigned
package, packaged smoke, security inventory and Node/Electron ABI restoration
passed.

Performance thresholds are measured with raw values in
`c02-performance-memory.json` and `c02-switch-performance.json`: 10k Worker
modern median 4.88 ms versus legacy 5.10 ms; exact heap returns from 35.14 MB
loaded to 6.44 MB after clear; 500 projects/1,000 tasks sustain 119.83 FPS with
no >50 ms long task; representative task/project switching beats the legacy
median and passed three consecutive runs.

Status: **RESOLVED — NO TECHNICAL CORRECTION REMAINS**.

## Resolution record: IP-03-08-C02-SCOPE-001 — 2026-08-22

C02 Required Change 4.3 required removing the no-op “more operations” button,
but its Allowed Scope omitted `ProjectLibraryPage.tsx`. The owner then directed
the agent to fix every reported problem and complete the architecture. That
instruction is applied narrowly to removal of that exact no-op symbol; it is
not a wildcard production-scope grant. The parent continuous package already
authorized the file. All other C02 production changes are within its enumerated
paths. The scope verifier now reports separate Gate/continuous/C02 attribution
and rejects unknown governance paths.

Status: **RESOLVED BY OWNER-DIRECT FINDING CLOSURE — NARROW SYMBOL ONLY**.

## Final-disposition requirement: IP-03-08-SAFETY-ISOLATION-001 — 2026-08-22

Technical containment and all later isolated validation are complete. The
quarantined path was not accessed during C02. The historical evidence still
cannot prove which rows were created or changed in the earlier unsafe run.
C02 requires the owner to explicitly accept that unprovable impact, confirm
the path was disposable, or authorize a separate content audit/recovery.

The owner's instruction to “修复所有问题，完成整个项目架构的变更” authorizes the
technical correction but does not expressly accept an unknown user-data
impact. Inferring that acceptance would exceed the data-safety authority.

Status: **BLOCKING FINAL APPROVAL — AWAITING EXPLICIT OWNER DISPOSITION UNDER
`packages/IP-03-08-C03.md`**.

## Owner disposition record: IP-03-08-SAFETY-ISOLATION-001 — 2026-08-22

The owner explicitly accepts that the historical unsafe test run's row-level
impact cannot be proven. The default macOS Project Library remains quarantined;
no content access, copy, hash, query, migration, restoration, deletion, or
cleanup is authorized by this disposition. This acceptance does not claim that
the quarantined contents were unchanged and does not authorize a future audit
without a separate path-exact package.

Status: **OWNER ACCEPTED — CLOSED FOR FINAL REVIEW**.
