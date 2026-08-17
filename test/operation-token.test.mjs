import assert from "node:assert/strict";
import test from "node:test";

import { createLatestOperation } from "../public/operation-token.js";

test("only the latest operation token may commit state", () => {
  const operation = createLatestOperation();
  const first = operation.start();
  const second = operation.start();

  assert.equal(operation.isCurrent(first), false);
  assert.equal(operation.isCurrent(second), true);

  // Selecting a new project/task invalidates work even when no replacement
  // request needs to be started immediately.
  operation.invalidate();
  assert.equal(operation.isCurrent(second), false);
});
