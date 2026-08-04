import test from "node:test";
import assert from "node:assert/strict";
import {
  canExportResolveCsv,
  canLoadResolveCsv,
  canSelectSlateDirectory,
  canStartRecognition,
} from "../public/workflow-state.js";

test("slate recognition can start before Resolve CSV is loaded", () => {
  assert.equal(
    canStartRecognition({
      reportReady: true,
      providerConfigured: true,
      modelSelected: true,
    }),
    true,
  );
  assert.equal(
    canStartRecognition({
      reportReady: false,
      providerConfigured: true,
      modelSelected: true,
    }),
    false,
  );
});

test("CSV export becomes available only after recognized rows can be merged", () => {
  assert.equal(
    canExportResolveCsv({
      metadataLoaded: false,
      recordCount: 12,
      exportableCount: 0,
    }),
    false,
  );
  assert.equal(
    canExportResolveCsv({
      metadataLoaded: true,
      recordCount: 12,
      exportableCount: 8,
    }),
    true,
  );
});

test("CSV unlocks after report preparation and stays available during recognition", () => {
  assert.equal(canLoadResolveCsv({ reportReady: false }), false);
  assert.equal(canLoadResolveCsv({ reportReady: true }), true);
  assert.equal(
    canSelectSlateDirectory({ reportReady: true, metadataLoaded: false }),
    false,
  );
  assert.equal(
    canSelectSlateDirectory({ reportReady: true, metadataLoaded: true }),
    true,
  );
});
