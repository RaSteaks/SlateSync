import { afterEach, describe, expect, it, vi } from "vitest";
import { CsvWorkerService, CSV_WORKER_PROTOCOL_VERSION } from "../../../src/renderer/services/csv-worker-service";

class FakeWorker {
  static instances: FakeWorker[] = [];
  readonly messages: Array<{ message: unknown; transfer: Transferable[] }> = [];
  private readonly listeners = new Map<string, Array<(event: unknown) => void>>();
  terminated = false;

  constructor() { FakeWorker.instances.push(this); }
  addEventListener(type: string, listener: (event: unknown) => void) {
    this.listeners.set(type, [...(this.listeners.get(type) || []), listener]);
  }
  postMessage(message: unknown, transfer: Transferable[] = []) { this.messages.push({ message, transfer }); }
  terminate() { this.terminated = true; }
  reply(result: unknown) {
    const message = this.messages.at(-1)?.message as { id: number };
    for (const listener of this.listeners.get("message") || []) listener({ data: { id: message.id, result } });
  }
  fail(message = "worker crashed") {
    for (const listener of this.listeners.get("error") || []) listener({ message });
  }
}

afterEach(() => {
  vi.unstubAllGlobals();
  FakeWorker.instances = [];
});

describe("typed CSV Worker service", () => {
  it("sends the versioned envelope and transfers the source ArrayBuffer", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    vi.stubGlobal("window", { location: { href: "file:///app/out/renderer/index.html" } });
    const service = new CsvWorkerService();
    const bytes = new ArrayBuffer(8);
    const pending = service.decode(bytes);
    const worker = FakeWorker.instances[0];
    expect(worker).toBeDefined();
    const sent = worker?.messages[0];
    expect(sent?.message).toMatchObject({ id: 1, version: CSV_WORKER_PROTOCOL_VERSION, task: { type: "decode-metadata", data: bytes } });
    expect(sent?.transfer).toEqual([bytes]);
    worker?.reply({ table: { headers: ["Scene"], rows: [["001"]], format: {} } });
    await expect(pending).resolves.toMatchObject({ headers: ["Scene"] });
  });

  it("classifies infrastructure failure, rejects pending work, and recreates once", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    vi.stubGlobal("window", { location: { href: "file:///app/out/renderer/index.html" } });
    const service = new CsvWorkerService();
    const pending = service.clear();
    const first = FakeWorker.instances[0];
    first?.fail("lost worker");
    await expect(pending).rejects.toMatchObject({ name: "CsvWorkerInfrastructureError", message: "lost worker" });
    const next = service.clear();
    expect(FakeWorker.instances).toHaveLength(2);
    FakeWorker.instances[1]?.reply({ ready: false });
    await expect(next).resolves.toBeUndefined();
  });
});
