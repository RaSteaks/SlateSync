import { afterEach, describe, expect, it, vi } from "vitest";
import { PreparationService } from "../../../src/renderer/services/preparation-service";

class FakeWorker {
  static latest: FakeWorker | null = null;
  readonly listeners = new Map<string, Array<(event: MessageEvent) => void>>();
  posted: unknown[] = [];
  terminated = false;

  constructor() { FakeWorker.latest = this; }
  addEventListener(type: string, listener: (event: MessageEvent) => void) {
    this.listeners.set(type, [...(this.listeners.get(type) || []), listener]);
  }
  postMessage(message: unknown) { this.posted.push(message); }
  terminate() { this.terminated = true; }
  emit(type: string, data: unknown) {
    for (const listener of this.listeners.get(type) || []) listener({ data } as MessageEvent);
  }
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  FakeWorker.latest = null;
});

describe("preparation service lifecycle", () => {
  it("caps burst progress at ten UI commits per second and delivers the latest value", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("Worker", FakeWorker);
    const service = new PreparationService();
    const progress = vi.fn();
    const promise = service.recompress([["data:image/jpeg;base64,AA=="]], { maxDimension: 1500, quality: 0.68 }, progress);
    const worker = FakeWorker.latest!;
    for (let index = 1; index <= 20; index += 1) worker.emit("message", { id: 1, type: "progress", progress: index, message: `step ${index}` });
    expect(progress).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(100);
    expect(progress).toHaveBeenCalledTimes(2);
    expect(progress).toHaveBeenLastCalledWith(20, "step 20");
    worker.emit("message", { id: 1, type: "recompressed", imageDataGroups: [["done"]] });
    await expect(promise).resolves.toEqual([["done"]]);
    service.terminate();
    expect(worker.terminated).toBe(true);
  });

  it("keeps active work alive but releases the worker once a hidden Workspace is idle", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const service = new PreparationService();
    const promise = service.recompress([["data:image/jpeg;base64,AA=="]], { maxDimension: 1500, quality: 0.68 }, vi.fn());
    const worker = FakeWorker.latest!;

    service.terminateWhenIdle();
    // Hiding Workspace cannot cancel a request whose result is still needed.
    expect(worker.terminated).toBe(false);
    worker.emit("message", { id: 1, type: "recompressed", imageDataGroups: [["done"]] });
    await expect(promise).resolves.toEqual([["done"]]);
    // Once the request settles, no idle preparation Worker remains attached.
    expect(worker.terminated).toBe(true);
  });

  it("cancels deferred idle cleanup when the Workspace returns", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const service = new PreparationService();
    const promise = service.recompress([["data:image/jpeg;base64,AA=="]], { maxDimension: 1500, quality: 0.68 }, vi.fn());
    const worker = FakeWorker.latest!;

    service.terminateWhenIdle();
    service.keepAlive();
    worker.emit("message", { id: 1, type: "recompressed", imageDataGroups: [["done"]] });
    await expect(promise).resolves.toEqual([["done"]]);
    expect(worker.terminated).toBe(false);
    service.terminate();
  });

  it("rejects pending work and clears deferred progress on termination", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("Worker", FakeWorker);
    const service = new PreparationService();
    const progress = vi.fn();
    const promise = service.recompress([["data:image/jpeg;base64,AA=="]], { maxDimension: 1500, quality: 0.68 }, progress);
    const worker = FakeWorker.latest!;
    worker.emit("message", { id: 1, type: "progress", progress: 1, message: "first" });
    worker.emit("message", { id: 1, type: "progress", progress: 2, message: "deferred" });
    service.terminate();
    await expect(promise).rejects.toThrow("场记单准备已停止");
    await vi.advanceTimersByTimeAsync(200);
    expect(progress).toHaveBeenCalledTimes(1);
  });

  it("returns only ordered page images when the worker finishes PDF preparation", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    const service = new PreparationService();
    const file = {
      type: "application/pdf",
      name: "sheet.pdf",
      arrayBuffer: async () => new ArrayBuffer(4),
    } as unknown as File;
    const promise = service.prepare(file, vi.fn());
    const worker = FakeWorker.latest!;
    await Promise.resolve();
    expect(worker.posted[0]).toMatchObject({ fileType: "application/pdf", filename: "sheet.pdf" });
    worker.emit("message", {
      id: 1,
      type: "result",
      pageCount: 2,
      imageDataGroups: [["data:image/jpeg;base64,one"], ["data:image/jpeg;base64,two"]],
      pdfDataUrl: "data:application/pdf;base64,retired",
    });
    const result = await promise;
    // The preparation boundary intentionally strips any historical PDF field;
    // only ordered page images may cross into recognition state.
    expect(result).toEqual({
      pageCount: 2,
      imageDataGroups: [["data:image/jpeg;base64,one"], ["data:image/jpeg;base64,two"]],
    });
    expect(result).not.toHaveProperty("pdfDataUrl");
    service.terminate();
  });
});
