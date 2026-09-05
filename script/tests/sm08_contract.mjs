import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fixtureRoot = join(repository, "Tests/SlateSyncUIUnitTests/Fixtures/SM08");
const read = path => readFileSync(join(repository, path), "utf8");
const readJSON = path => JSON.parse(readFileSync(path, "utf8"));
const digest = data => createHash("sha256").update(data).digest("hex");
const expectedIDs = [
  ...ids("APP", 6), ...ids("PRJ", 8), ...ids("TSK", 8), ...ids("REC", 8),
  ...ids("CSV", 8), ...ids("SET", 8), ...ids("LOG", 4), ...ids("A11Y", 5),
  ...ids("PERF", 3), "GOV-01",
];

function ids(prefix, count) {
  return Array.from({ length: count }, (_, index) => `${prefix}-${String(index + 1).padStart(2, "0")}`);
}

export function validateState(state) {
  assert.equal(state.lifecycleState, "COMPLETE");
  assert.ok(["SM-07", "SM-08"].includes(state.phase));
  assert.equal(state.activePackage, `.codex/swift-migration/packages/${state.phase}.md`);
  assert.equal(state.nextPackage, `.codex/swift-migration/packages/${state.phase === "SM-07" ? "SM-08" : "SM-09"}.md`);
}

export function validateFixtures(
  sourceManifest = readJSON(join(fixtureRoot, "source-manifest.json")),
  fixtureManifest = readJSON(join(fixtureRoot, "fixture-manifest.json")),
  budget = readJSON(join(fixtureRoot, "performance-budget.json")),
) {
  assert.equal(sourceManifest.phase, "SM-08");
  assert.equal(sourceManifest.networkRequired, false);
  for (const source of sourceManifest.sources) {
    assert.equal(digest(readFileSync(join(repository, source.path))), source.sha256, source.path);
  }
  assert.equal(fixtureManifest.applicationSupport, "explicit-temporary-root-only");
  assert.deepEqual(fixtureManifest.fixtures.map(value => value.count), [500, 1_000, 10_000]);
  assert.ok(fixtureManifest.edgeCases.includes("IME"));
  assert.equal(budget.samples, 5);
  assert.equal(budget.warmups, 1);
  assert.equal(budget.csv10000.visibleViewsMax, 300);
  assert.equal(budget.release.timerCountAfterClose, 0);
}

export function validateCoverage(coverage = readJSON(join(fixtureRoot, "sm08-coverage.json"))) {
  const automated = new Set(coverage.automated);
  const manual = new Set(coverage.manualOrGate);
  assert.equal(automated.size, coverage.automated.length, "duplicate automated acceptance ID");
  assert.equal(manual.size, coverage.manualOrGate.length, "duplicate manual/Gate acceptance ID");
  for (const id of automated) assert.ok(!manual.has(id), `${id} has two evidence lanes`);
  assert.deepEqual([...automated, ...manual].sort(), [...expectedIDs].sort());
  assert.deepEqual(Object.keys(coverage.automatedEvidence).sort(), [...automated].sort());
  for (const [id, tests] of Object.entries(coverage.automatedEvidence)) {
    assert.ok(tests.length, id);
    for (const test of tests) validateTestReference(test, id);
  }
  assert.ok(coverage.regressionEvidence?.length, "independent-review/native regressions are required");
  for (const test of coverage.regressionEvidence) validateTestReference(test, "regression");
}

// Qualified references let the Gate require actual AppKit execution alongside
// model tests without misattributing all native evidence to one XCTest class.
function testReference(reference) {
  const parts = reference.split("/");
  const [suite, test] = parts.length === 1 ? ["SM08OwnershipTests", parts[0]] : parts;
  assert.ok(parts.length <= 2 && ["SM08OwnershipTests", "SM08NativeSurfaceTests"].includes(suite));
  assert.match(test, /^test[A-Za-z0-9_]+$/);
  return { suite, test };
}

function validateTestReference(reference, id) {
  const { suite, test } = testReference(reference);
  assert.ok(read(`Tests/SlateSyncUIUnitTests/${suite}.swift`).includes(`func ${test}(`), `${id}: missing ${reference}`);
}

export function assertExecuted(coverage, swiftLog) {
  for (const [id, tests] of Object.entries({ ...coverage.automatedEvidence, regression: coverage.regressionEvidence ?? [] })) {
    for (const reference of tests) {
      const { suite, test } = testReference(reference);
      assert.ok(
        swiftLog.includes(`Test Case '-[SlateSyncUIUnitTests.${suite} ${test}]' passed`),
        `${id}: no executed PASS for ${reference}`,
      );
    }
  }
}

// A named manual lane is not evidence. Native interaction/measurement reports
// must cover every remaining acceptance ID, identify the exact source tree,
// and retain hashed raw artifacts. Missing evidence is a real Gate failure.
export function sourceFingerprint() {
  const paths = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"], { cwd: repository, encoding: "utf8" })
    .trim().split("\n")
    .filter(path => /^(Sources\/|Tests\/|SlateSyncApp\/|SlateSyncUITests\/|script\/|Package\.swift$|SlateSync\.xcodeproj\/|SlateSync\.xctestplan$)/.test(path));
  return digest([...new Set(paths)].sort().map(path => {
    try { return `${path}\0${digest(readFileSync(join(repository, path)))}`; }
    catch (error) { if (error.code === "ENOENT") return `${path}\0deleted`; throw error; }
  }).join("\n"));
}

export function validateNativeEvidence(report, coverage, fingerprint = sourceFingerprint()) {
  assert.equal(report?.schemaVersion, 1, "native evidence report is required");
  assert.equal(report.phase, "SM-08");
  assert.equal(report.sourceFingerprint, fingerprint, "native evidence is stale after source changes");
  assert.ok(Number.isFinite(Date.parse(report.generatedAt)), "native evidence timestamp is required");
  const required = coverage.manualOrGate.filter(id => id !== "GOV-01");
  assert.deepEqual(Object.keys(report.acceptance).sort(), [...required].sort());
  for (const id of required) {
    const entry = report.acceptance[id];
    assert.equal(entry.result, "PASS", `${id}: acceptance did not pass`);
    assert.ok(entry.assertions?.length > 0 && entry.command?.length > 0, `${id}: no executed assertions/command`);
    assert.ok(entry.artifacts?.length > 0, `${id}: no retained raw evidence`);
    for (const artifact of entry.artifacts) {
      assert.equal(digest(readFileSync(resolve(repository, artifact.path))), artifact.sha256, `${id}: artifact drift`);
    }
  }
}

function sourceAudit() {
  const packageSource = read("Package.swift");
  const uiTarget = packageSource.match(/\.target\(\s*name: "SlateSyncUI",([\s\S]*?)\n\s*\),/)?.[1] ?? "";
  assert.match(uiTarget, /"SlateSyncDomain"/);
  assert.match(uiTarget, /"SlateSyncWorkflow"/);
  assert.doesNotMatch(uiTarget, /SlateSyncPersistence|SlateSyncMedia/);

  const app = read("SlateSyncApp/App/SlateSyncApp.swift");
  for (const token of ["WindowGroup", "Settings {", ".defaultSize(width: 1440, height: 900)", ".frame(minWidth: 960, minHeight: 600)"]) {
    assert.ok(app.includes(token), token);
  }
  assert.equal((app.match(/NSApplicationDelegate/g) ?? []).length, 2);
  assert.doesNotMatch(app, /NSHostingView|NSWindow\s*\(/);

  const uiFiles = readdirSync(join(repository, "Sources/SlateSyncUI"), { recursive: true })
    .filter(path => String(path).endsWith(".swift"))
    .map(path => join("Sources/SlateSyncUI", String(path)));
  const uiSource = uiFiles.map(read).join("\n");
  const bridges = uiFiles.filter(path => /:\s*NSViewRepresentable/.test(read(path)));
  assert.deepEqual(bridges.sort(), [
    "Sources/SlateSyncUI/App/WindowLifecycleBridge.swift",
    "Sources/SlateSyncUI/CSV/EditableCSVTableRepresentable.swift",
  ]);
  assert.doesNotMatch(uiSource, /URLSession|import SQLite3|import SlateSyncPersistence|Process\s*\(/);
  assert.match(read("Sources/SlateSyncUI/Workspace/WorkspaceAutosave.swift"), /milliseconds\(500\)/);
  assert.match(read("Sources/SlateSyncUI/CSV/EditableCSVTableRepresentable.swift"), /milliseconds\(250\)/);
  assert.match(read("Sources/SlateSyncUI/Logs/LogsModel.swift"), /seconds\(3\)/);

  const logs = read("Sources/SlateSyncPersistence/LocalLogStore.swift");
  for (const token of ["retentionDays = 7", "defaultReadLimit = 500", "maximumReadLimit = 2_000", "LOCK_EX", "0o700", "0o600"]) {
    assert.ok(logs.includes(token), token);
  }
  const installer = read("Sources/SlateSyncWorkflow/PaddleOCRInstallerService.swift");
  for (const token of ["3.3.1", "3.7.0", "30 * 60", ".detectPython, 5", ".createEnvironment, 20", ".installDependencies, 35", ".verify, 90", ".completed, 100", "SIGTERM", "SIGKILL", "lstat(requirementsURL.path"]) {
    assert.ok(installer.includes(token), token);
  }
  assert.equal((read("Sources/SlateSyncUI/Help/HelpModel.swift").match(/\.init\(id:/g) ?? []).length, 6);
  assert.match(read("SlateSync.xcodeproj/project.pbxproj"), /pinned OCR requirements in Resources/);
  assert.match(read("AGENT.md"), /SM-08/);
}

export function runSelfTests() {
  const sourceManifest = structuredClone(readJSON(join(fixtureRoot, "source-manifest.json")));
  sourceManifest.sources[0].sha256 = "0".repeat(64);
  assert.throws(() => validateFixtures(sourceManifest));
  const fixtureManifest = structuredClone(readJSON(join(fixtureRoot, "fixture-manifest.json")));
  fixtureManifest.fixtures[2].count = 9_999;
  assert.throws(() => validateFixtures(undefined, fixtureManifest));
  const coverage = structuredClone(readJSON(join(fixtureRoot, "sm08-coverage.json")));
  coverage.manualOrGate = coverage.manualOrGate.filter(id => id !== "GOV-01");
  assert.throws(() => validateCoverage(coverage));
  validateState({ phase: "SM-07", lifecycleState: "COMPLETE", activePackage: ".codex/swift-migration/packages/SM-07.md", nextPackage: ".codex/swift-migration/packages/SM-08.md" });
  assert.throws(() => validateState({ phase: "SM-08", lifecycleState: "IN_PROGRESS" }));
  assert.throws(() => assertExecuted({ automatedEvidence: { "APP-05": ["testRouteBarrierKeepsWorkspaceAndDraftWhenAutosaveFails"] } }, ""));
  assert.throws(() => validateNativeEvidence(undefined, coverage, "test-fingerprint"));
  assert.throws(() => validateNativeEvidence({ schemaVersion: 1, phase: "SM-08", sourceFingerprint: "stale" }, coverage, "test-fingerprint"));
  assert.throws(() => validateNativeEvidence({ schemaVersion: 1, phase: "SM-08", sourceFingerprint: "test-fingerprint", generatedAt: "2026-09-06T00:00:00Z", acceptance: {} }, coverage, "test-fingerprint"));
  console.log("SM-08 governance negative tests: source drift, fixture shrink, coverage gap, invalid state and absent execution rejected");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  validateFixtures();
  const coverage = readJSON(join(fixtureRoot, "sm08-coverage.json"));
  validateCoverage(coverage);
  runSelfTests();
  if (!process.argv.includes("--self-test")) {
    validateState(readJSON(join(repository, ".codex/swift-migration/CURRENT_STATE.json")));
    sourceAudit();
    const index = process.argv.indexOf("--swift-log");
    assert.ok(index >= 0 && process.argv[index + 1], "--swift-log is required; static-only contract cannot PASS");
    assertExecuted(coverage, readFileSync(process.argv[index + 1], "utf8"));
    const nativeIndex = process.argv.indexOf("--native-evidence");
    assert.ok(nativeIndex >= 0 && process.argv[nativeIndex + 1], "--native-evidence is required; manualOrGate names cannot establish PASS");
    validateNativeEvidence(readJSON(process.argv[nativeIndex + 1]), coverage);
    console.log("SM-08 contract PASS: frozen sources, all acceptance IDs, executed UI ownership tests, AppKit allowlist and phase admission verified");
  }
}
