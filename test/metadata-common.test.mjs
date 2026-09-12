import assert from "node:assert/strict";
import test from "node:test";
import {
  canonicalRecognitionValue,
  normalizeRecognitionField,
  normalizeRecognitionRecord,
  normalizeRecognitionSheetFields,
  parseChineseNumber,
  reviewFieldsFromQuality,
} from "../public/metadata-common.js";

const fieldFormats = { scene: "XXX", shot: "XX", take: "XX" };

test("shared recognition normalization covers Chinese numerals, widths, and review provenance", () => {
  const cases = [
    ["scene", "二〇三", "203", true, "chinese-numeral-converted"],
    ["scene", "一〇五", "105", true, "chinese-numeral-converted"],
    ["scene", "〇七", "007", true, "chinese-numeral-converted"],
    ["shot", "十一", "11", true, "chinese-numeral-converted"],
    ["take", "一百零五", "105", true, "chinese-numeral-converted"],
    ["scene", "一百二十", "120", true, "chinese-numeral-converted"],
    ["scene", "二百〇三", "203", true, "chinese-numeral-converted"],
    ["scene", "1百", "1百", true, "invalid-numeric-token"],
    ["take", "1十", "1十", true, "invalid-numeric-token"],
    ["scene", "3百5", "3百5", true, "invalid-numeric-token"],
    ["scene", "３７a / 58", "37A / 58", false, null],
    ["take", "9", "09", false, null],
    ["take", "100", "100", false, null],
    ["shot", "十百", "十百", true, "invalid-numeric-token"],
    ["scene", "1000000", "1000000", true, "out-of-range"],
    ["shot", "O8", "08", true, "confusable-character"],
    ["scene", "12O", "12O", true, "ambiguous-numeric-token"],
    ["videoCode", null, null, false, null],
  ];

  for (const [field, value, expected, reviewRequired, warningCode] of cases) {
    const input = { field, value };
    const before = structuredClone(input);
    const first = normalizeRecognitionField(field, value, {
      fieldFormats,
      confidence: "high",
    });
    const second = normalizeRecognitionField(field, value, {
      fieldFormats,
      confidence: "high",
    });
    assert.deepEqual(first, second, String(field) + ":" + String(value) + " must be idempotent");
    assert.notStrictEqual(first.warnings, second.warnings, "warnings must be fresh arrays");
    assert.deepEqual(input, before, "normalization must not mutate caller input");
    assert.equal(first.normalizedValue, expected, String(field) + ":" + String(value));
    assert.equal(first.reviewRequired, reviewRequired, String(field) + ":" + String(value) + " review");
    if (warningCode) {
      assert.ok(first.warnings.some((warning) => warning.code === warningCode));
    } else {
      assert.equal(first.warnings.length, 0);
    }
  }
});

test("Chinese numeral parser rejects ambiguous grammar and preserves numeric context", () => {
  assert.deepEqual(
    ["二〇三", "一〇五", "〇七", "十一", "一百零五", "一百二十", "二百〇三"].map(parseChineseNumber),
    [203, 105, 7, 11, 105, 120, 203],
  );
  for (const value of ["十百", "百十十", "十一二", "十点五", "-1", "1.5"]) {
    assert.equal(parseChineseNumber(value), null, value);
  }
  assert.equal(canonicalRecognitionValue("cardNumber", "B001"), "B001");
  assert.equal(canonicalRecognitionValue("cardNumber", "A1B"), null);
  assert.equal(canonicalRecognitionValue("videoCode", "C115"), null);
  assert.equal(canonicalRecognitionValue("videoCode", "C1234"), null);
  assert.equal(canonicalRecognitionValue("videoCode", "C O 1"), "C001");
});

test("record normalization preserves identity, evidence, old review fields, and historical quality", () => {
  const record = {
    id: "record-1",
    targetId: "target-1",
    sourcePage: 4,
    cardNumber: "A001",
    videoCode: "C001",
    scene: "二〇三",
    shot: "2",
    take: "9",
    confidence: "medium",
    reviewRequiredFields: ["legacy-review", "take", "scene", "scene"],
    ocrEvidence: { bbox: [0.1, 0.2, 0.3, 0.4], text: "二〇三" },
  };
  const normalized = normalizeRecognitionRecord(record, { fieldFormats });
  assert.equal(normalized.id, record.id);
  assert.equal(normalized.targetId, record.targetId);
  assert.equal(normalized.sourcePage, record.sourcePage);
  assert.deepEqual(normalized.ocrEvidence, record.ocrEvidence);
  assert.equal(normalized.scene, "203");
  assert.equal(normalized.take, "09");
  assert.deepEqual(normalized.reviewRequiredFields, ["scene", "take", "legacy-review"]);
  assert.equal(normalized.quality.fields.scene.originalValue, "二〇三");
  assert.equal(normalized.quality.fields.scene.reviewRequired, true);
  assert.equal(normalized.quality.fields.take.reviewRequired, true);

  const historicalWarning = {
    code: "chinese-numeral-converted",
    field: "scene",
    message: "历史 warning",
    originalValue: "二〇三",
    normalizedValue: "203",
  };
  const restored = {
    ...record,
    scene: "人工确认值",
    reviewRequiredFields: ["legacy-review", "take", "scene"],
    quality: {
      fields: {
        scene: {
          field: "scene",
          originalValue: "二〇三",
          normalizedValue: "203",
          changed: true,
          confidence: "high",
          reviewRequired: true,
          warnings: [historicalWarning],
        },
      },
    },
  };
  const restoredResult = normalizeRecognitionRecord(restored, { fieldFormats });
  assert.equal(restoredResult.scene, "人工确认值");
  assert.deepEqual(restoredResult.quality.fields.scene.warnings, [historicalWarning]);
  assert.deepEqual(reviewFieldsFromQuality(restoredResult), ["scene", "take", "legacy-review"]);
});

test("sheet normalization changes field values without changing result shape or order", () => {
  const result = {
    sheetTitle: "Day 01",
    warnings: ["existing"],
    records: [
      { id: "first", targetId: "target-first", sourcePage: 1, scene: "二〇三", confidence: "high" },
      { id: "second", targetId: "target-second", sourcePage: 2, scene: "12O", confidence: "low" },
    ],
  };
  const normalized = normalizeRecognitionSheetFields(result, { fieldFormats });
  assert.deepEqual(normalized.records.map((record) => record.id), ["first", "second"]);
  assert.deepEqual(normalized.records.map((record) => record.targetId), ["target-first", "target-second"]);
  assert.equal(normalized.records.length, result.records.length);
  assert.equal(normalized.records[0].scene, "203");
  assert.equal(normalized.records[1].scene, "12O");
  assert.equal(normalized.records[1].quality.fields.scene.reviewRequired, true);
});
