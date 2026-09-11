import assert from "node:assert/strict";
import test from "node:test";

import {
  isRecognitionTargetId,
  manualRecognitionTargetId,
  recognitionTargetId,
  restoreRecognitionTargetId,
} from "../public/recognition-target.js";

test("recognition target IDs use final-sheet page and global record position", () => {
  assert.equal(recognitionTargetId(2, 7), "page:2:record:7");
  assert.equal(recognitionTargetId(null, 0), "page:unknown:record:0");
  assert.equal(recognitionTargetId(2, -1), null);
  assert.equal(recognitionTargetId(2, 1.5), null);
  assert.ok(isRecognitionTargetId("page:2:record:7"));
  assert.ok(isRecognitionTargetId("page:unknown:record:0"));
  assert.equal(isRecognitionTargetId("page:0:record:1"), false);
});

test("manual records use a separate non-crop identity namespace", () => {
  assert.equal(manualRecognitionTargetId("abc/123"), "manual:abc-123");
  assert.equal(manualRecognitionTargetId(""), "manual:record");
  assert.equal(isRecognitionTargetId("manual:abc-123"), false);
});

test("legacy persisted records derive targets once while valid targets win", () => {
  assert.equal(restoreRecognitionTargetId(null, 3, 4), "page:3:record:4");
  assert.equal(restoreRecognitionTargetId("page:2:record:9", 3, 4), "page:2:record:9");
  assert.equal(restoreRecognitionTargetId("manual:kept", 3, 4), "manual:kept");
  assert.equal(restoreRecognitionTargetId("ui-record-id", null, 4), "page:unknown:record:4");
});
