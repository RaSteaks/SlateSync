import test from "node:test";
import assert from "node:assert/strict";
import {
  clearCustomProviderProbeState,
  defaultPendingSelection,
  mergeCustomProviderDiscovery,
} from "../public/custom-provider-state.js";

test("legacy custom-provider state excludes canceled models from default selection", () => {
  assert.deepEqual(
    defaultPendingSelection([
      { id: "pending", capabilityStatus: "pending" },
      { id: "canceled", capabilityStatus: "canceled" },
    ]),
    ["pending"],
  );
});

test("legacy discovery refresh keeps search and explicit selection", () => {
  const merged = mergeCustomProviderDiscovery(
    {
      search: "vision",
      selectedPending: ["keep", "canceled", "removed"],
      probing: true,
      progress: { completed: 1, total: 2 },
    },
    {
      models: [{ id: "fresh" }],
      pendingModels: [
        { id: "keep", capabilityStatus: "pending" },
        { id: "canceled", capabilityStatus: "canceled" },
      ],
    },
  );

  assert.equal(merged.search, "vision");
  assert.deepEqual(merged.selectedPending, ["keep"]);
  assert.equal(merged.models[0].id, "fresh");
  assert.equal(merged.probing, true);
  assert.deepEqual(
    clearCustomProviderProbeState(merged),
    { ...merged, probing: false, progress: null },
  );
});
