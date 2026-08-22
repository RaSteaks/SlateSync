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
});
