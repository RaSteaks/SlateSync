import assert from "node:assert/strict";
import test from "node:test";
import {
  requestBodyBytes,
  requestBodyFits,
  requestBodyTargetBytes,
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
