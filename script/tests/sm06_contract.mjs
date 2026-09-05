import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync,writeFileSync,readdirSync,mkdtempSync,cpSync,rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname,join,resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repository = resolve(dirname(fileURLToPath(import.meta.url)),"../..");
const fixtureRoot = join(repository,"Tests/SlateSyncMediaTests/Fixtures/SM06");
const readJSON = path => JSON.parse(readFileSync(path,"utf8"));
const digest = data => createHash("sha256").update(data).digest("hex");
const expectedIDs = [...Array.from({length:9},(_,i)=>`MED-${String(i+1).padStart(2,"0")}`),...Array.from({length:5},(_,i)=>`VIS-${String(i+1).padStart(2,"0")}`),...Array.from({length:10},(_,i)=>`PAD-${String(i+1).padStart(2,"0")}`),...Array.from({length:6},(_,i)=>`OCR-${String(i+1).padStart(2,"0")}`),"INT-01","INT-02","INT-03","RES-01","GOV-01"];

export function validateState(state) {
  assert.equal(state.lifecycleState,"COMPLETE");
  assert.ok(["SM-05","SM-06"].includes(state.phase));
  assert.equal(state.activePackage,`.codex/swift-migration/packages/${state.phase}.md`);
  assert.equal(state.nextPackage,`.codex/swift-migration/packages/${state.phase==="SM-05" ? "SM-06" : "SM-07"}.md`);
}
export function validateFixtures(root = fixtureRoot) {
  const manifest = readJSON(join(root,"manifest.json"));
  assert.equal(manifest.rasterAcceptance.frozenBeforeNativeImplementation,true);
  for(const [name,expected] of Object.entries(manifest.files)) {
    const data=readFileSync(join(root,name));assert.equal(data.length,expected.bytes,name);assert.equal(digest(data),expected.sha256,name);
  }
  for(const entry of [...manifest.sources,...(manifest.workflowFiles||[])]) {
    const data=readFileSync(join(repository,entry.path));assert.equal(data.length,entry.bytes,entry.path);assert.equal(digest(data),entry.sha256,entry.path);
  }
  const actual=readdirSync(root).filter(name=>!["manifest.json","coverage.json"].includes(name)).sort();
  assert.deepEqual(actual,Object.keys(manifest.files).sort(),"all fixture resources must be frozen");
}
export function validateCoverage(coverage) {
  assert.deepEqual(Object.keys(coverage).sort(),expectedIDs.sort(),"coverage IDs must be complete");
  for(const [id,entry] of Object.entries(coverage)) {
    if(id==="GOV-01") { assert.equal(entry.lane,"selftest");continue; }
    assert.equal(entry.lane,id==="PAD-10" ? "paddle" : "swift",`${id} cannot bypass its executable lane`);
    assert.ok(entry.tests?.length,id);
    for(const test of entry.tests) {
      const [target,className,method] = test.split("/");
      const source=readFileSync(join(repository,"Tests",target,`${className}.swift`),"utf8");
      assert.ok(source.includes(`func ${method}(`),`${id} maps to nonexistent test`);
    }
  }
}
export function offlineEvidenceState(log) {
  // An explicitly absent fixture is an environment block, never a fake PASS.
  // Assertion/crash evidence takes precedence, matching the shared Gate rules.
  if (/Test Case .*failed|XCTAssert|AssertionError|assertion failed|fatal error|crash/i.test(log)) return "FAIL";
  if (/missing required tool\/environment:/.test(log)) return "BLOCKED_ENV";
  return "REQUIRE_PASS";
}
function assertExecuted(coverage,swiftLog,paddleLog) {
  // Source names alone do not establish coverage. The exact mapped XCTest
  // cases must have completed successfully in the current Gate's actual logs.
  assert.notEqual(offlineEvidenceState(paddleLog),"FAIL","actual Paddle assertion/exit failure cannot be replaced by an environment block");
  for(const [id,entry] of Object.entries(coverage)) {
    if(entry.lane==="selftest")continue;
    if(entry.lane==="paddle" && offlineEvidenceState(paddleLog)==="BLOCKED_ENV")continue;
    const log=entry.lane==="paddle" ? paddleLog : swiftLog;
    for(const test of entry.tests) {
      const [target,className,method] = test.split("/");
      assert.ok(log.includes(`Test Case '-[${target}.${className} ${method}]' passed`),`${id}: no executed PASS for ${test}`);
    }
  }
  assert.match(swiftLog,/SM06_RESOURCES .*active=0 pending=0 processes=0/);
  assert.match(swiftLog,/SM06_VISION_SMOKE .*revision=[1-9][0-9]*/);
  if(offlineEvidenceState(paddleLog)==="BLOCKED_ENV")return "BLOCKED_ENV";
  assert.equal((paddleLog.match(/SM06_PADDLE_INFERENCE/g)||[]).length,2);
  return "PASS";
}
function scopeAudit() {
  const media = readdirSync(join(repository,"Sources/SlateSyncMedia")).filter(n=>n.endsWith(".swift"));
  for(const name of media) {
    const source=readFileSync(join(repository,"Sources/SlateSyncMedia",name),"utf8");
    assert.match(source,/\/\//,`${name}: ownership/compatibility comments missing`);
    assert.doesNotMatch(source,/@unchecked\s+Sendable|try!|as!|import SlateSyncPersistence|import SQLite3|URLSession|homeDirectoryForCurrentUser/);
  }
  const workflow=readFileSync(join(repository,"Sources/SlateSyncWorkflow/MediaOCRWorkflow.swift"),"utf8");
  assert.doesNotMatch(workflow,/URLSession|SQLite|import SlateSyncPersistence/);
  assert.ok(readFileSync(join(repository,"AGENT.md"),"utf8").includes("SM-06"));
  const project=readFileSync(join(repository,"SlateSync.xcodeproj/project.pbxproj"),"utf8");
  assert.match(project,/shared Paddle runner in Resources/);
}
export function runSelfTests() {
  const temporary=mkdtempSync(join(tmpdir(),"sm06-contract-"));
  try {
    cpSync(fixtureRoot,temporary,{recursive:true});
    const path=join(temporary,"geometry.json"),original=readFileSync(path);
    const changed=Buffer.from(original);changed[0]^=1;writeFileSync(path,changed);
    assert.throws(()=>validateFixtures(temporary));writeFileSync(path,original);
    const coverage=readJSON(join(temporary,"coverage.json")).coverage;delete coverage["MED-01"];
    assert.throws(()=>validateCoverage(coverage));
    const bypass=readJSON(join(temporary,"coverage.json")).coverage;bypass["MED-01"].lane="selftest";
    assert.throws(()=>validateCoverage(bypass));
    for(const phase of ["SM-05","SM-06"]) validateState({phase,lifecycleState:"COMPLETE",activePackage:`.codex/swift-migration/packages/${phase}.md`,nextPackage:`.codex/swift-migration/packages/${phase==="SM-05" ? "SM-06" : "SM-07"}.md`});
    for(const state of [{phase:"SM-04",lifecycleState:"COMPLETE"},{phase:"SM-06",lifecycleState:"IN_PROGRESS"},{phase:"SM-06",lifecycleState:"COMPLETE",nextPackage:"SM-09"}]) assert.throws(()=>validateState(state));
    assert.throws(()=>assertExecuted({"VIS-01":{lane:"swift",tests:["SlateSyncMediaTests/OCRContractTests/testVisionNormalizationMatchesExtractedHelper"]}},"", ""));
    assert.equal(offlineEvidenceState("missing required tool/environment: offline fixture"),"BLOCKED_ENV");
    assert.equal(offlineEvidenceState("missing required tool/environment: fixture\nTest Case 'inference' failed"),"FAIL");
    console.log("SM-06 governance negative tests: fixture mutation, missing coverage, wrong phase and absent executed evidence rejected");
  } finally { rmSync(temporary,{recursive:true,force:true}); }
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  validateFixtures();const coverage=readJSON(join(fixtureRoot,"coverage.json")).coverage;validateCoverage(coverage);runSelfTests();
  if(!process.argv.includes("--self-test")) {
    validateState(readJSON(join(repository,".codex/swift-migration/CURRENT_STATE.json")));scopeAudit();
    const value=key=>{const index=process.argv.indexOf(key);assert.ok(index>=0,`${key} required; a static-only contract cannot PASS`);return readFileSync(process.argv[index+1],"utf8");};
    if(assertExecuted(coverage,value("--swift-log"),value("--paddle-log"))==="BLOCKED_ENV") {
      console.error("missing required tool/environment: SM-06 actual Paddle evidence remains BLOCKED_ENV");process.exitCode=127;
    } else console.log("SM-06 contract PASS: frozen sources, executed test coverage, native media/OCR ownership, isolated lifecycle and phase admission verified");
  }
}
