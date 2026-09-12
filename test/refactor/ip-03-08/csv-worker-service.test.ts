import { afterEach, describe, expect, it, vi } from "vitest";
import { CsvWorkerService, CSV_WORKER_PROTOCOL_VERSION } from "../../../src/renderer/services/csv-worker-service";

class FakeWorker {
  static instances: FakeWorker[] = [];
  readonly messages: Array<{ message: unknown; transfer: Transferable[] }> = [];
  private readonly listeners = new Map<string, Array<(event: unknown) => void>>();
  terminated = false;
  readonly url: string;

  constructor(url: URL | string) {
    this.url = String(url);
    FakeWorker.instances.push(this);
  }
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
    expect(worker?.url).toBe("file:///app/public/csv-worker.js");
    const sent = worker?.messages[0];
    expect(sent?.message).toMatchObject({ id: 1, version: CSV_WORKER_PROTOCOL_VERSION, task: { type: "decode-metadata", data: bytes } });
    expect(sent?.transfer).toEqual([bytes]);
    worker?.reply({ table: { headers: ["Scene"], rows: [["001"]], format: {} } });
    await expect(pending).resolves.toMatchObject({ headers: ["Scene"] });
  });

  it("uses the Vite-owned source URL only when the dev marker is present", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    vi.stubGlobal("window", { location: { href: "http://localhost:5173/", origin: "http://localhost:5173" } });
    vi.stubGlobal("__SLATESYNC_CSV_WORKER_DEV_URL__", "/@fs//repo/public/csv-worker.js");
    const service = new CsvWorkerService();
    const pending = service.clear();
    const worker = FakeWorker.instances[0];

    expect(worker?.url).toBe("http://localhost:5173/@fs//repo/public/csv-worker.js");
    worker?.reply({ ready: true });
    await expect(pending).resolves.toBeUndefined();
  });

  it("requests a Worker-derived merge table for the preview", async () => {
    vi.stubGlobal("Worker", FakeWorker);
    vi.stubGlobal("window", { location: { href: "file:///app/out/renderer/index.html" } });
    const service = new CsvWorkerService();
    const pending = service.mergePreview({
      type: "merge-preview",
      records: [],
      slateMetadata: [],
      fieldFormats: { scene: "XXX", shot: "XX", take: "XX" },
      comments: { goodTake: "_OK", holdTake: "_KP" },
    });
    const worker = FakeWorker.instances[0];
    expect(worker?.messages[0]?.message).toMatchObject({ task: { type: "merge-preview" } });
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

// Run the production processor behind the modern envelope rather than mocking
// export values, so this test detects payload omissions and preview divergence.
it("modern export payload matches direct/fallback bytes and failure retains store data", async () => {
  // @ts-expect-error The public processor is the shared JavaScript authority.
  const { createCsvTaskProcessor } = await import("../../../public/csv-background-tasks.js");
  // @ts-expect-error The builder is shared with the legacy renderer and Node.
  const { buildSemanticExportTable, encodeResolveCsv } = await import("../../../public/resolve-csv.js");
  const { useExportStore } = await import("../../../src/renderer/state/export-store");
  const { DEFAULT_EXPORT_OPTIONS } = await import("../../../src/shared/contracts/index");
  type RecordValue = import("../../../src/shared/contracts/index").RecognitionRecord;
  const processor = createCsvTaskProcessor();
  class ProcessingWorker extends FakeWorker {
    override postMessage(message: unknown, transfer: Transferable[] = []) {
      super.postMessage(message, transfer);
      const envelope = message as { task: unknown };
      queueMicrotask(() => {
        const result = processor(envelope.task);
        this.reply(result.bytes instanceof Uint8Array ? { ...result, bytes: result.bytes.buffer } : result);
      });
    }
  }
  vi.stubGlobal("Worker", ProcessingWorker);
  vi.stubGlobal("window", { location: { href: "file:///app/out/renderer/index.html" } });
  const service = new CsvWorkerService();
  const table = { headers: ["File Name", "Scene", "Shot", "Take"], rows: [["A001C001.mov", "", "", ""]], format: { encoding: "utf-8" as const } };
  const records = [{ cardNumber: "A001", videoCode: "C001", scene: "1", shot: "2", take: "3", takeStatus: "过" }] as RecordValue[];
  const payload = { records, slateMetadata: [], fieldFormats: { scene: "XXX", shot: "XX", take: "XX" }, comments: { goodTake: "_OK", holdTake: "_KP" }, csvEdits: [["0:1", "9"]] as const, exportOptions: DEFAULT_EXPORT_OPTIONS, resolvedFilename: "resolved.csv" };
  await service.prime(table);
  const preview = await service.mergePreview({ type: "merge-preview", ...payload });
  const bytes = await service.exportResolve({ type: "export-resolve", ...payload });
  const direct = buildSemanticExportTable({ mode: "resolve", sourceTable: table, ...payload });
  expect(preview).toEqual(direct.table);
  expect(new Uint8Array(bytes)).toEqual(encodeResolveCsv(direct.table));
  useExportStore.getState().setTable(table, "source.csv");
  useExportStore.getState().setPreviewTable(preview);
  useExportStore.getState().setEdits({ "0:1": "9" });
  const before = useExportStore.getState();
  FakeWorker.instances[0]?.fail();
  useExportStore.getState().setError("worker crashed");
  expect(useExportStore.getState()).toMatchObject({ table: before.table, previewTable: before.previewTable, edits: before.edits, filename: "source.csv" });
  await service.prime(table);
  expect(FakeWorker.instances).toHaveLength(2);
  expect(await service.exportResolve({ type: "export-resolve", ...payload })).toEqual(bytes);
  service.terminate();
  useExportStore.getState().clear();
});
