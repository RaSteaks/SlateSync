import assert from "node:assert/strict";
import test from "node:test";
import { scanSlateDirectory } from "../public/slate-directory.js";

test("scanner reaches a matching slate.txt four directories below the root", async () => {
  const slate = mockFile(
    "A001C001_DEMO001-slate.txt",
    "Clip Name: A001C001_DEMO001\nSensor FPS: 48",
  );
  const video = mockFile("A001C001_DEMO001.mov", "video bytes");
  const root = mockDirectory("Video", {
    "day-001": mockDirectory("day-001", {
      A001_media: mockDirectory("A001_media", {
        master: mockDirectory("master", {
          A001C001_DEMO001: mockDirectory(
            "A001C001_DEMO001",
            {
              [slate.name]: slate,
              [video.name]: video,
            },
          ),
        }),
      }),
    }),
  });

  const result = await scanSlateDirectory(root, {
    expectedKeys: ["A:1:1"],
    maxDepth: 4,
  });

  assert.equal(result.metadata.length, 1);
  assert.equal(result.metadata[0].materialKey, "A:1:1");
  assert.equal(result.metadata[0].sensorFps, "48");
  assert.equal(slate.arrayBufferCalls, 1);
  assert.equal(video.getFileCalls, 0, "video content must never be opened");
  assert.equal(result.stats.visitedDirectories, 5);
});

test("scanner stops beyond configured depth and reports the skipped directory", async () => {
  const slate = mockFile(
    "A001C001_DEMO001-slate.txt",
    "Clip Name: A001C001_DEMO001\nSensor FPS: 48",
  );
  const root = mockDirectory("Video", {
    one: mockDirectory("one", {
      two: mockDirectory("two", {
        three: mockDirectory("three", {
          A001C001_DEMO001: mockDirectory(
            "A001C001_DEMO001",
            { [slate.name]: slate },
          ),
        }),
      }),
    }),
  });

  const result = await scanSlateDirectory(root, {
    expectedKeys: ["A:1:1"],
    maxDepth: 3,
  });

  assert.equal(result.metadata.length, 0);
  assert.equal(result.stats.skippedDeepDirectories, 1);
  assert.match(result.warnings.join("\n"), /超过配置的 3 层/);
  assert.equal(slate.getFileCalls, 0);
});

test("scanner prunes material directories absent from Resolve CSV", async () => {
  const unrelatedSlate = mockFile(
    "A001C002-slate.txt",
    "Clip Name: A001C002\nSensor FPS: 96",
  );
  const root = mockDirectory("Video", {
    A001C002: mockDirectory("A001C002", {
      [unrelatedSlate.name]: unrelatedSlate,
    }),
  });

  const result = await scanSlateDirectory(root, {
    expectedKeys: ["A:1:1"],
    maxDepth: 4,
  });

  assert.equal(result.metadata.length, 0);
  assert.equal(result.stats.prunedDirectories, 1);
  assert.equal(unrelatedSlate.getFileCalls, 0);
});

test("scanner falls back to another slate.txt name and reuses session cache", async () => {
  const slate = mockFile(
    "camera-slate.txt",
    "Clip Name: A004C004_DEMO002\nSensor FPS: 47.952",
  );
  const root = mockDirectory("Video", {
    A004C004_DEMO002: mockDirectory("A004C004_DEMO002", {
      [slate.name]: slate,
    }),
  });
  const cache = new Map();

  const first = await scanSlateDirectory(root, {
    expectedKeys: ["A:4:4"],
    maxDepth: 4,
    cache,
  });
  const second = await scanSlateDirectory(root, {
    expectedKeys: ["A:4:4"],
    maxDepth: 4,
    cache,
  });

  assert.equal(first.metadata[0].sensorFps, "47.952");
  assert.equal(second.metadata[0].sensorFps, "47.952");
  assert.equal(second.stats.cacheHits, 1);
  assert.equal(slate.arrayBufferCalls, 1);
});

function mockDirectory(name, entries) {
  return {
    kind: "directory",
    name,
    async *entries() {
      for (const entry of Object.entries(entries)) yield entry;
    },
    async getFileHandle(fileName) {
      const handle = entries[fileName];
      if (handle?.kind === "file") return handle;
      const error = new Error(`${fileName} not found`);
      error.name = "NotFoundError";
      throw error;
    },
  };
}

function mockFile(name, source) {
  const bytes = new TextEncoder().encode(source);
  return {
    kind: "file",
    name,
    getFileCalls: 0,
    arrayBufferCalls: 0,
    async getFile() {
      this.getFileCalls += 1;
      const handle = this;
      return {
        name,
        size: bytes.byteLength,
        lastModified: 1_700_000_000_000,
        async arrayBuffer() {
          handle.arrayBufferCalls += 1;
          return bytes.buffer.slice(
            bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength,
          );
        },
      };
    },
  };
}
