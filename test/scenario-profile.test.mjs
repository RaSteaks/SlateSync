import assert from "node:assert/strict";
import { access, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  createScenarioObservation,
  normalizeScenarioProfile,
  scenarioSimilarity,
} from "../lib/scenario/profile.mjs";
import { createScenarioStore } from "../lib/scenario/store.mjs";

function syntheticOcrResult() {
  return {
    id: "paddleocr",
    used: true,
    pages: [
      {
        pageNumber: 1,
        views: [
          {
            width: 1200,
            height: 800,
            blocks: [
              { text: "场次", confidence: 0.99, bboxNormalized: [0.05, 0.08, 0.12, 0.12] },
              { text: "镜", confidence: 0.99, bboxNormalized: [0.2, 0.08, 0.25, 0.12] },
              { text: "次", confidence: 0.99, bboxNormalized: [0.3, 0.08, 0.35, 0.12] },
              { text: "A机", confidence: 0.99, bboxNormalized: [0.7, 0.08, 0.78, 0.12] },
              { text: "87A", confidence: 0.95, bboxNormalized: [0.05, 0.45, 0.12, 0.5] },
              { text: "01", confidence: 0.95, bboxNormalized: [0.2, 0.45, 0.25, 0.5] },
              { text: "02", confidence: 0.95, bboxNormalized: [0.3, 0.45, 0.35, 0.5] },
            ],
          },
        ],
      },
    ],
  };
}

test("scenario observation produces reusable canonical fields and fingerprint", () => {
  const observation = createScenarioObservation(syntheticOcrResult(), {
    filename: "episode-01-slate.png",
  });
  const profile = normalizeScenarioProfile(observation, {
    fieldFormats: { scene: "XXXX", shot: "XXX", take: "X" },
    comments: { goodTake: "OK", holdTake: "HOLD" },
  });

  assert.equal(observation.source.filename, "episode-01-slate.png");
  assert.equal(profile.fingerprint.length, 32);
  assert.deepEqual(profile.output.resolve.fieldFormats, {
    scene: "XXXX",
    shot: "XXX",
    take: "X",
  });
  assert.equal(profile.fields.scene.region[0], 0.05);
  assert.equal(profile.fields.scene.required, true);
  assert.equal(scenarioSimilarity(profile, profile), 1);
});

test("scenario store creates once, reuses matches, and persists in SQLite", async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "slatesync-scenario-"));
  const store = createScenarioStore(dataDir, {
    matching: { threshold: 0.85, ambiguityMargin: 0.05 },
  });

  try {
    const observation = createScenarioObservation(syntheticOcrResult(), {
      filename: "first.png",
    });
    const first = await store.matchAndSave(observation);
    const second = await store.matchAndSave({
      ...observation,
      label: "second.png",
    });

    assert.equal(first.match, "created");
    assert.equal(second.match, "reused");
    assert.equal(second.profile.id, first.profile.id);
    assert.equal((await store.listProfiles())[0].sampleCount, 2);
    await access(join(dataDir, "slatesync.sqlite"));

    const imported = await store.importProfile(first.profile);
    assert.equal(imported.id, first.profile.id);
  } finally {
    await store.close();
    await rm(dataDir, { recursive: true, force: true });
  }
});
