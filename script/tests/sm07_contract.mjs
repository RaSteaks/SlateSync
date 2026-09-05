import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  CORE_AUDIT_SYSTEM_PROMPT,
  CORE_REVIEW_SYSTEM_PROMPT,
  CORE_SLATE_SCHEMA,
  SLATE_SCHEMA,
  SYSTEM_PROMPT,
} from "../../lib/schema.mjs";
import { SYNTHETIC_PROBE_MARKER } from "../../lib/model-capabilities.mjs";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fixtureRoot = join(repository, "Tests/SlateSyncWorkflowTests/Fixtures/SM07");
const readJSON = path => JSON.parse(readFileSync(path, "utf8"));
const digest = value => createHash("sha256").update(value).digest("hex");
const expectedIDs = [
  ...Array.from({ length: 5 }, (_, index) => `REG-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 10 }, (_, index) => `NET-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 6 }, (_, index) => `DIS-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 3 }, (_, index) => `PRB-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 6 }, (_, index) => `PRM-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 8 }, (_, index) => `NOR-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 7 }, (_, index) => `PAG-${String(index + 1).padStart(2, "0")}`),
  ...Array.from({ length: 10 }, (_, index) => `FLW-${String(index + 1).padStart(2, "0")}`),
  "RES-01",
  "GOV-01",
];

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}

export function validateState(state) {
  assert.equal(state.lifecycleState, "COMPLETE");
  assert.ok(["SM-06", "SM-07"].includes(state.phase));
  assert.equal(state.activePackage, `.codex/swift-migration/packages/${state.phase}.md`);
  assert.equal(state.nextPackage, `.codex/swift-migration/packages/${state.phase === "SM-06" ? "SM-07" : "SM-08"}.md`);
}

export function validateManifest(manifest = readJSON(join(fixtureRoot, "sm07-manifest.json"))) {
  assert.equal(manifest.phase, "SM-07");
  assert.equal(manifest.oracleCapturedFromRetainedBaseline, true);
  assert.equal(manifest.networkRequired, false);
  for (const entry of manifest.sources) {
    const data = readFileSync(join(repository, entry.path));
    assert.equal(data.length, entry.bytes, entry.path);
    assert.equal(digest(data), entry.sha256, entry.path);
  }
  const oracles = manifest.canonicalOracles;
  const values = {
    systemPrompt: Buffer.from(SYSTEM_PROMPT),
    auditPrompt: Buffer.from(CORE_AUDIT_SYSTEM_PROMPT),
    reviewPrompt: Buffer.from(CORE_REVIEW_SYSTEM_PROMPT),
    fullSchemaCanonicalJSON: Buffer.from(JSON.stringify(canonical(SLATE_SCHEMA))),
    coreSchemaCanonicalJSON: Buffer.from(JSON.stringify(canonical(CORE_SLATE_SCHEMA))),
  };
  for (const [name, data] of Object.entries(values)) {
    assert.equal(data.length, oracles[name].bytes, name);
    assert.equal(digest(data), oracles[name].sha256, name);
  }
  const legacyProbe = readFileSync(join(repository, "lib/model-capabilities.mjs"), "utf8")
    .match(/const SYNTHETIC_PROBE_IMAGE\s*=\s*\n?\s*"data:image\/png;base64,([A-Za-z0-9+/=]+)";/)?.[1];
  assert.ok(legacyProbe, "legacy synthetic PNG missing");
  const probeData = Buffer.from(legacyProbe, "base64");
  assert.equal(probeData.length, oracles.syntheticProbePNG.bytes);
  assert.equal(digest(probeData), oracles.syntheticProbePNG.sha256);
  assert.equal(SYNTHETIC_PROBE_MARKER, oracles.syntheticProbePNG.marker);
  assert.equal(manifest.frozenPolicies.maximumResponseBytes, 16 * 1024 * 1024);
}

function swiftRaw(source, name) {
  const match = source.match(new RegExp(`public static let ${name} = #\"\"\"([\\s\\S]*?)\"\"\"#`));
  assert.ok(match, `${name} Swift prompt missing`);
  return match[1].slice(1, -1);
}

export function validateSwiftOracles(source = readFileSync(join(repository, "Sources/SlateSyncWorkflow/RecognitionPrompts.swift"), "utf8")) {
  const system = swiftRaw(source, "system"), audit = swiftRaw(source, "audit");
  const reviewMatch = source.match(/public static let review = audit \+ "\\n\\n" \+ #"""([\s\S]*?)"""#/);
  assert.ok(reviewMatch, "review Swift prompt missing");
  const review = audit + "\n\n" + reviewMatch[1].slice(1, -1);
  assert.equal(system, SYSTEM_PROMPT);
  assert.equal(audit, CORE_AUDIT_SYSTEM_PROMPT);
  assert.equal(review, CORE_REVIEW_SYSTEM_PROMPT);
  const probeSource = readFileSync(join(repository, "Sources/SlateSyncWorkflow/ModelCapabilityProbeService.swift"), "utf8");
  const swiftProbe = probeSource.match(/syntheticProbePNGBase64 = "([A-Za-z0-9+/=]+)"/)?.[1];
  assert.ok(swiftProbe, "Swift synthetic PNG missing");
  assert.equal(swiftProbe, readFileSync(join(repository, "lib/model-capabilities.mjs"), "utf8").match(/data:image\/png;base64,([A-Za-z0-9+/=]+)/)?.[1]);
}

export function validateCoverage(coverage) {
  assert.deepEqual(Object.keys(coverage).sort(), expectedIDs.sort());
  for (const [id, entry] of Object.entries(coverage)) {
    if (id === "GOV-01") { assert.equal(entry.lane, "selftest"); continue; }
    assert.equal(entry.lane, "swift", `${id} cannot bypass executable Swift coverage`);
    assert.ok(entry.tests?.length, id);
    for (const test of entry.tests) {
      const [target, className, method] = test.split("/");
      const source = readFileSync(join(repository, "Tests", target, `${className}.swift`), "utf8");
      assert.ok(source.includes(`func ${method}(`), `${id} maps to nonexistent test ${test}`);
    }
  }
}

export function assertExecuted(coverage, swiftLog) {
  for (const [id, entry] of Object.entries(coverage)) {
    if (entry.lane === "selftest") continue;
    for (const test of entry.tests) {
      const [target, className, method] = test.split("/");
      assert.ok(swiftLog.includes(`Test Case '-[${target}.${className} ${method}]' passed`), `${id}: no executed PASS for ${test}`);
    }
  }
}

function scopeAudit() {
  const workflowFiles = [
    "ModelCapabilityProbeService.swift", "ModelDiscoveryService.swift", "ProviderCatalog.swift",
    "ProviderPayloadBuilder.swift", "ProviderRegistry.swift", "RecognitionCoordinator.swift",
    "RecognitionNormalizer.swift", "RecognitionPagePipeline.swift", "RecognitionPostprocessor.swift",
    "RecognitionPrompts.swift", "RecognitionSchemas.swift", "URLSessionProviderTransport.swift",
  ];
  for (const name of workflowFiles) {
    const source = readFileSync(join(repository, "Sources/SlateSyncWorkflow", name), "utf8");
    assert.match(source, /\/\//, `${name}: ownership or compatibility comment missing`);
    assert.doesNotMatch(source, /@unchecked\s+Sendable|URLSession\.shared|try!|as!/);
  }
  const allSource = workflowFiles.map(name => readFileSync(join(repository, "Sources/SlateSyncWorkflow", name), "utf8")).join("\n");
  assert.doesNotMatch(allSource, /pdfDataUrl\s*[:=]|pricePerMillion|\bcost\s*:/);
  assert.match(readFileSync(join(repository, "AGENT.md"), "utf8"), /SM-07/);
}

export function runSelfTests() {
  const manifest = structuredClone(readJSON(join(fixtureRoot, "sm07-manifest.json")));
  manifest.sources[0].sha256 = "0".repeat(64);
  assert.throws(() => validateManifest(manifest));
  const coverage = structuredClone(readJSON(join(fixtureRoot, "sm07-coverage.json")).coverage);
  delete coverage["NET-01"];
  assert.throws(() => validateCoverage(coverage));
  const bypass = structuredClone(readJSON(join(fixtureRoot, "sm07-coverage.json")).coverage);
  bypass["NET-01"].lane = "selftest";
  assert.throws(() => validateCoverage(bypass));
  const prompt = readFileSync(join(repository, "Sources/SlateSyncWorkflow/RecognitionPrompts.swift"), "utf8").replace("影视制作场记单", "影视制作场记表");
  assert.throws(() => validateSwiftOracles(prompt));
  assert.throws(() => assertExecuted({ "REG-01": { lane: "swift", tests: ["SlateSyncWorkflowTests/SM07RegistryTests/testREG01BuiltinsAndPhysicalModelRouting"] } }, ""));
  validateState({ phase: "SM-06", lifecycleState: "COMPLETE", activePackage: ".codex/swift-migration/packages/SM-06.md", nextPackage: ".codex/swift-migration/packages/SM-07.md" });
  validateState({ phase: "SM-07", lifecycleState: "COMPLETE", activePackage: ".codex/swift-migration/packages/SM-07.md", nextPackage: ".codex/swift-migration/packages/SM-08.md" });
  assert.throws(() => validateState({ phase: "SM-07", lifecycleState: "IN_PROGRESS" }));
  console.log("SM-07 governance negative tests: source mutation, missing coverage, bypass lane, prompt drift, absent execution and wrong state rejected");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  validateManifest();
  validateSwiftOracles();
  const coverage = readJSON(join(fixtureRoot, "sm07-coverage.json")).coverage;
  validateCoverage(coverage);
  runSelfTests();
  if (!process.argv.includes("--self-test")) {
    validateState(readJSON(join(repository, ".codex/swift-migration/CURRENT_STATE.json")));
    scopeAudit();
    const index = process.argv.indexOf("--swift-log");
    assert.ok(index >= 0 && process.argv[index + 1], "--swift-log is required; static-only contract cannot PASS");
    assertExecuted(coverage, readFileSync(process.argv[index + 1], "utf8"));
    console.log("SM-07 contract PASS: frozen sources/oracles, 57 executed coverage IDs, secret-safe native ownership and phase admission verified");
  }
}
