import assert from "node:assert/strict";
import test from "node:test";
import {
  applyCropRecheckResults,
  batchCropRecheckTargets,
  normalizeCropRecheckConfig,
  selectCropRecheckTargets,
} from "../lib/crop-recheck.mjs";

const coreImage = "data:image/jpeg;base64,Y29yZQ==";
const cropImage = "data:image/jpeg;base64,Y3JvcA==";

function fixture(overrides = {}) {
  return {
    records: [{
      targetId: "page-1-row-1",
      sourcePage: 1,
      scene: "12",
      shot: "03",
      take: "01",
      confidence: "medium",
      quality: { fields: { scene: { confidence: "low", reviewRequired: true } } },
      ...overrides,
    }],
    ocrResult: {
      pages: [{
        pageNumber: 1,
        views: [{
          blocks: [{ text: "12", confidence: 0.91, bboxNormalized: [0.1, 0.2, 0.2, 0.25], cropImage }],
        }],
      }],
    },
    imageDataGroups: [[coreImage]],
    accuracyMode: "high",
  };
}

test("crop recheck stays disabled by default and clamps the hard bound", () => {
  assert.deepEqual(normalizeCropRecheckConfig({}), { enabled: false, maxTargets: 12, timeoutMs: 120000, batchSize: 3 });
  assert.equal(normalizeCropRecheckConfig({ enabled: true, maxTargets: 999 }).maxTargets, 64);
  assert.equal(normalizeCropRecheckConfig({ enabled: true, maxTargets: 0 }).maxTargets, 0);
  assert.equal(selectCropRecheckTargets(fixture(), { enabled: true, maxTargets: 0 }).targets.length, 0);
  assert.equal(selectCropRecheckTargets(fixture(), {}).targets.length, 0);
});

test("selection requires high accuracy, stable identity, bbox, and an actual crop", () => {
  const selected = selectCropRecheckTargets(fixture(), { enabled: true, maxTargets: 12 });
  assert.equal(selected.targets.length, 1);
  assert.deepEqual(selected.targets[0], {
    targetId: "page-1-row-1",
    sourcePage: 1,
    field: "scene",
    currentValue: "12",
    coreImage,
    cropImage,
    bboxNormalized: [0.1, 0.2, 0.2, 0.25],
    reason: "review-required",
  });

  const noCropFixture = fixture({ targetId: "page-1-row-2" });
  delete noCropFixture.ocrResult.pages[0].views[0].blocks[0].cropImage;
  const withoutCrop = selectCropRecheckTargets(noCropFixture, { enabled: true });
  assert.equal(withoutCrop.targets.length, 0);
});

test("crop recheck batching and result application preserve confirmed fields", () => {
  assert.deepEqual(batchCropRecheckTargets([1, 2, 3, 4], 3), [[1, 2, 3], [4]]);
  const records = [{ targetId: "a", sourcePage: 1, scene: "", quality: { fields: { scene: { confidence: "low", reviewRequired: true } } } }, { targetId: "b", sourcePage: 1, scene: "confirmed" }];
  const applied = applyCropRecheckResults(records, [
    { targetId: "a", sourcePage: 1, field: "scene", value: "12", status: "confirmed", confidence: "high" },
    { targetId: "b", sourcePage: 1, field: "scene", value: "99", status: "confirmed", confidence: "high" },
  ], [{ targetId: "a", field: "scene", sourcePage: 1, currentValue: "", coreImage, cropImage, bboxNormalized: [0, 0, 1, 1], reason: "review-required" }], { fieldFormats: { scene: "XX" } });
  assert.equal(applied.records[0].scene, "12");
  assert.equal(applied.records[1].scene, "confirmed");
  assert.equal(applied.confirmed, 2);
});

// Repeated cell values are common in slates; OCR confidence cannot identify rows.
test("selection skips repeated record values and cross-field collisions", () => {
  const input = fixture();
  input.records.push({ targetId: "other", sourcePage: 1, scene: "12", confidence: "high" });
  assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets.length, 0);
  assert.equal(selectCropRecheckTargets(fixture({ shot: "12" }), { enabled: true }).targets.length, 0);
});

test("selection never resolves multiple OCR regions by confidence", () => {
  const input = fixture();
  input.ocrResult.pages[0].views[0].blocks.push({ text: "12", confidence: 0.99, bboxNormalized: [0.1, 0.8, 0.2, 0.9], cropImage: "wrong-row" });
  assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets.length, 0);
});

test("selection requires an exact cell value without collapsing scene punctuation", () => {
  for (const text of ["C012", "112", "1-2", "12 03 01"]) {
    const input = fixture();
    input.ocrResult.pages[0].views[0].blocks[0].text = text;
    assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets.length, 0, text);
  }
});

test("selection uses the emitting view and skips unavailable or duplicated views", () => {
  const input = fixture();
  input.ocrResult.pages[0].views[0].viewIndex = 2;
  input.imageDataGroups = [["full", "upper", "lower"]];
  assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets[0].coreImage, "lower");
  input.imageDataGroups = [["full"]];
  assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets.length, 0);
  input.imageDataGroups = [["full", "upper", "lower"]];
  input.ocrResult.pages[0].views.push({ ...input.ocrResult.pages[0].views[0], viewIndex: 0 });
  assert.equal(selectCropRecheckTargets(input, { enabled: true }).targets.length, 0);
});
