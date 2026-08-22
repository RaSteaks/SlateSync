#!/usr/bin/env node

// Refactor governance spans historical evidence and current instructions. This
// verifier makes the one executable package and its accepted Gate
// machine-checkable without rewriting any frozen baseline or evidence file.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const refactorRoot = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(refactorRoot, "../..");
const state = JSON.parse(await readFile(join(refactorRoot, "CURRENT_STATE.json"), "utf8"));

// The authority has two valid lifecycle states: implementation admission and
// the immutable handoff to Sol. Keeping the transition in this verifier makes
// the machine-readable phase and the final-review report path auditable
// without changing any production ownership or runtime contract.
const supportedPhases = new Set([
  "IP-03-08_READY_FOR_CONTINUOUS_IMPLEMENTATION",
  "IP-03-08_READY_FOR_FINAL_REVIEW",
]);
assert(supportedPhases.has(state.phase), `unsupported authority phase: ${state.phase}`);
if (state.phase === "IP-03-08_READY_FOR_FINAL_REVIEW") {
  assert.equal(
    state.completionReport,
    ".codex/refactor/evidence/IP-03-08/CONTINUOUS_COMPLETION_REPORT.md",
  );
}
assert.equal(state.admissionGate.verdict, "APPROVED");
assert.equal(state.activeImplementationPackage.soleExecutablePackage, true);
assert.equal(state.activeImplementationPackage.intermediateImplementationGates, false);
// A C03 handoff may remain blocked by the quarantined-library safety decision.
// Any other blocker, or a blocker without the boundary-only correction package,
// is an invalid authority state rather than a valid review disposition.
const allowedBlockingDecisionIds =
  state.finalHandoff?.status === "BLOCKED_OWNER_SAFETY_DISPOSITION"
    && state.activeCorrectionPackage?.path === ".codex/refactor/packages/IP-03-08-C03.md"
    ? ["IP-03-08-SAFETY-ISOLATION-001"]
    : [];
assert.deepEqual(state.foundation.blockingDecisionIds, allowedBlockingDecisionIds);

// The ignore-file change is intentionally authorized outside the production
// refactor scope. Require its standalone record and exact one-file boundary so
// future hygiene edits cannot silently broaden this authority state.
assert.equal(
  state.hygieneAuthorization?.decisionId,
  "IP-03-08-REPO-HYGIENE-001",
);
assert.equal(
  state.hygieneAuthorization?.path,
  ".codex/refactor/evidence/IP-03-08/final-handoff/GITIGNORE-HYGIENE-AUTHORIZATION.md",
);
assert.deepEqual(state.hygieneAuthorization?.scope, [".gitignore"]);
assert.equal(state.hygieneAuthorization?.productionChangesAuthorized, false);
const hygieneRecord = await readFile(
  resolve(repositoryRoot, state.hygieneAuthorization.path),
  "utf8",
);
assert(hygieneRecord.includes("IP-03-08-REPO-HYGIENE-001"));
assert(hygieneRecord.includes("OWNER AUTHORIZED — STANDALONE"));

const packagePath = resolve(repositoryRoot, state.activeImplementationPackage.path);
const packageText = await readFile(packagePath, "utf8");
const packageSha256 = createHash("sha256").update(packageText).digest("hex");
assert.equal(packageSha256, state.activeImplementationPackage.sha256, "active package hash drift");
assert(packageText.includes(`PACKAGE VERSION: **${state.activeImplementationPackage.version} — current**`));
assert(packageText.includes("STATUS: **AUTHORIZED"));

for (const heading of [
  "## Objective",
  "## Allowed Scope",
  "## Protected Scope",
  "## Required Changes / Workstreams",
  "## Existing Behavior That Must Remain",
  "## Public Interfaces and State Ownership",
  "## Acceptance Tests / Final Acceptance Matrix",
  "## Performance Constraints",
  "## Stop Conditions",
  "## Deliverables",
  "## Continuous Completion Report",
  "## Sol Final Review",
]) {
  assert(packageText.includes(heading), `active package missing ${heading}`);
}

const gateText = await readFile(resolve(repositoryRoot, state.admissionGate.path), "utf8");
assert(gateText.includes("VERDICT: APPROVED"));
assert(gateText.includes(state.activeImplementationPackage.path));

for (const historicalPath of state.historicalNonExecutablePackages) {
  const historicalText = await readFile(resolve(repositoryRoot, historicalPath), "utf8");
  assert.match(
    historicalText.slice(0, 1_500),
    /NOT AN EXECUTABLE PACKAGE|NOT EXECUTABLE|NOT RESUMABLE/,
    `${historicalPath} lacks a non-executable status banner`,
  );
}

const packageNames = await readdir(join(refactorRoot, "packages"));
for (const forbiddenName of [
  "IP-03.md",
  "IP-04.md",
  "IP-05.md",
  "IP-05A.md",
  "IP-05B.md",
  "IP-05C.md",
  "IP-06.md",
  "IP-06A.md",
  "IP-06B.md",
  "IP-06C.md",
  "IP-07.md",
  "IP-08.md",
]) {
  assert(!packageNames.includes(forbiddenName), `${forbiddenName} must not become a parallel executable package`);
}

const authorityIndex = await readFile(join(refactorRoot, "README.md"), "utf8");
assert(authorityIndex.includes("Sole executable implementation package"));
assert(authorityIndex.includes(state.activeImplementationPackage.path.replace(".codex/refactor/", "")));

const traceability = await readFile(
  resolve(repositoryRoot, state.historicalRequirementTraceability),
  "utf8",
);
for (const historicalLabel of [
  "IP-03",
  "IP-04",
  "IP-05A",
  "IP-05B",
  "IP-05C",
  "IP-06A",
  "IP-06B and IP-06C",
  "IP-07",
  "IP-08",
]) {
  assert(traceability.includes(`| ${historicalLabel} |`), `traceability missing ${historicalLabel}`);
}

process.stdout.write(
  `REFACTOR_AUTHORITY_OK ${state.activeImplementationPackage.version} ${packageSha256}\n`,
);
