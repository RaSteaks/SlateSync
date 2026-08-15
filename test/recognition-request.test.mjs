import assert from "node:assert/strict";
import test from "node:test";
import {
  requestBodyBytes,
  requestBodyFits,
  requestBodyTargetBytes,
  selectRecognitionImageGroups,
  serializeRecognitionRequest,
} from "../public/recognition-request.js";

test("recognition request sizing counts UTF-8 bytes and reserves headroom", () => {
  const body = serializeRecognitionRequest({
    provider: "openrouter",
    model: "openai/gpt-5.6-terra",
    filename: "示例项目场记单.pdf",
    imageDataGroups: [["data:image/jpeg;base64,ZmFrZQ=="]],
    pageCount: 1,
  });

  assert.equal(requestBodyBytes(body), Buffer.byteLength(body, "utf8"));
  assert.equal(requestBodyTargetBytes(1_000), 940);
  assert.equal(requestBodyFits(body, requestBodyBytes(body)), false);
  assert.equal(requestBodyFits(body, requestBodyBytes(body) / 0.94 + 1), true);
});

test("recognition request carries the custom prompt only when non-empty", () => {
  const base = {
    provider: "openai",
    model: "openai/gpt-4o-mini",
    filename: "slate.jpg",
    imageDataGroups: [["data:image/jpeg;base64,ZmFrZQ=="]],
    pageCount: 1,
  };

  const withPrompt = JSON.parse(
    serializeRecognitionRequest({ ...base, customPrompt: "  民国题材  " }),
  );
  assert.equal(withPrompt.customPrompt, "民国题材");

  const withoutPrompt = JSON.parse(serializeRecognitionRequest(base));
  assert.equal("customPrompt" in withoutPrompt, false);
});

test("recognition request carries an explicitly selected scenario Profile", () => {
  const body = JSON.parse(
    serializeRecognitionRequest({
      provider: "openai",
      model: "openai/gpt-4o-mini",
      filename: "slate.jpg",
      imageDataGroups: [["data:image/jpeg;base64,ZmFrZQ=="]],
      pageCount: 1,
      scenarioId: "scenario-0123456789abcdef",
    }),
  );
  assert.equal(body.scenarioId, "scenario-0123456789abcdef");
});

test("recognition request preserves an explicit fast mode and defaults safely", () => {
  const base = {
    provider: "openai",
    model: "openai/gpt-4o-mini",
    filename: "slate.jpg",
    imageDataGroups: [["data:image/jpeg;base64,ZmFrZQ=="]],
    pageCount: 1,
  };

  assert.equal(
    JSON.parse(serializeRecognitionRequest({ ...base, accuracyMode: "standard" })).accuracyMode,
    "standard",
  );
  assert.equal(
    JSON.parse(serializeRecognitionRequest({ ...base, accuracyMode: "invalid" })).accuracyMode,
    "high",
  );
});

test("fast mode sends only the full-page view while precise mode keeps detail views", () => {
  const groups = [["full-1", "detail-1a", "detail-1b"], ["full-2", "detail-2a"]];

  assert.deepEqual(selectRecognitionImageGroups(groups, "standard"), [
    ["full-1"],
    ["full-2"],
  ]);
  assert.equal(selectRecognitionImageGroups(groups, "high"), groups);
  assert.equal(groups[0].length, 3);
});
