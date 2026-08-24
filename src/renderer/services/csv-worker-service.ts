import type { RecognitionRecord, ResolveCsvTable, ScannedSlateMetadata, SlateCsvRecord } from "../../shared/contracts/index.js";

declare const __SLATESYNC_CSV_WORKER_DEV_URL__: string;

export const CSV_WORKER_PROTOCOL_VERSION = 1 as const;

type CsvTask =
  | { readonly type: "decode-metadata"; readonly data: ArrayBuffer }
  | { readonly type: "prime-metadata"; readonly table: ResolveCsvTable }
  | { readonly type: "clear-metadata" }
  | { readonly type: "collect-material-keys" }
  | { readonly type: "decode-slate-csv"; readonly data: ArrayBuffer }
  | { readonly type: "records-from-slate-csv"; readonly records: readonly SlateCsvRecord[] }
  | {
      readonly type: "export-resolve";
      readonly records: readonly RecognitionRecord[];
      readonly csvEdits: readonly (readonly [string, string])[];
      readonly slateMetadata: readonly ScannedSlateMetadata[];
      readonly fieldFormats: { readonly scene: string; readonly shot: string; readonly take: string };
      readonly comments: { readonly goodTake: string; readonly holdTake: string };
    }
  | {
      readonly type: "export-standalone";
      readonly records: readonly RecognitionRecord[];
      readonly fieldFormats: { readonly scene: string; readonly shot: string; readonly take: string };
      readonly comments: { readonly goodTake: string; readonly holdTake: string };
    };

type WorkerReply = { readonly id: number; readonly result?: unknown; readonly error?: string };

interface Pending<T> {
  resolve(value: T): void;
  reject(error: Error): void;
}

function workerFailure(message: string) {
  const error = new Error(message);
  error.name = "CsvWorkerInfrastructureError";
  return error;
}

/**
 * Modern mode never runs CSV algorithms in React. This service owns one
 * retained Worker, recreates it after an infrastructure failure, and only
 * transfers input bytes/results across the boundary.
 */
export class CsvWorkerService {
  private worker: Worker | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, Pending<unknown>>();

  private createWorker(): Worker {
    if (typeof Worker !== "function") throw workerFailure("当前环境不支持 CSV Worker");
    // Vite owns repository-level module resolution in HMR mode. Production
    // intentionally keeps the established file:// path to the Worker packaged
    // once under public/, so this development repair cannot widen that shell.
    const devUrl = typeof __SLATESYNC_CSV_WORKER_DEV_URL__ === "undefined"
      ? ""
      : __SLATESYNC_CSV_WORKER_DEV_URL__;
    const url = devUrl
      ? new URL(devUrl, window.location.origin)
      : new URL("../../public/csv-worker.js", window.location.href);
    const worker = new Worker(url, { type: "module" });
    worker.addEventListener("message", (event: MessageEvent<WorkerReply>) => this.handleMessage(event.data));
    worker.addEventListener("error", (event) => this.handleFailure(worker, event.message || "CSV Worker 不可用"));
    return worker;
  }

  private ensureWorker(): Worker {
    if (!this.worker) this.worker = this.createWorker();
    return this.worker;
  }

  private handleMessage(message: WorkerReply) {
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    if (message.error) {
      const error = new Error(message.error);
      error.name = "CsvWorkerTaskError";
      pending.reject(error);
      return;
    }
    pending.resolve(message.result);
  }

  private handleFailure(worker: Worker, message: string) {
    if (this.worker !== worker) return;
    this.worker = null;
    worker.terminate();
    const error = workerFailure(message);
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }

  request<T>(task: CsvTask, transfer: Transferable[] = []): Promise<T> {
    const worker = this.ensureWorker();
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      try {
        // The version is an internal envelope marker; the existing algorithm
        // Worker ignores unknown envelope fields, preserving byte semantics.
        worker.postMessage({ id, version: CSV_WORKER_PROTOCOL_VERSION, task }, transfer);
      } catch (error) {
        this.pending.delete(id);
        reject(error instanceof Error ? error : workerFailure("CSV Worker 请求失败"));
      }
    });
  }

  async decode(data: ArrayBuffer) {
    const result = await this.request<{ table: ResolveCsvTable }>({ type: "decode-metadata", data }, [data]);
    return result.table;
  }

  async prime(table: ResolveCsvTable) {
    await this.request<{ ready: boolean }>({ type: "prime-metadata", table });
  }

  async clear() {
    await this.request<{ ready: boolean }>({ type: "clear-metadata" });
  }

  async collectMaterialKeys() {
    const result = await this.request<{ keys: string[] }>({ type: "collect-material-keys" });
    return result.keys;
  }

  async decodeSlateCsv(data: ArrayBuffer) {
    const result = await this.request<{ records: SlateCsvRecord[] }>({ type: "decode-slate-csv", data }, [data]);
    return result.records;
  }

  async recordsFromSlateCsv(records: readonly SlateCsvRecord[]) {
    const result = await this.request<{ records: RecognitionRecord[] }>({ type: "records-from-slate-csv", records });
    return result.records;
  }

  async exportResolve(task: Extract<CsvTask, { type: "export-resolve" }>) {
    const result = await this.request<{ bytes: ArrayBuffer }>({ ...task, csvEdits: [...task.csvEdits] });
    return result.bytes;
  }

  async exportStandalone(task: Extract<CsvTask, { type: "export-standalone" }>) {
    const result = await this.request<{ bytes: ArrayBuffer }>(task);
    return result.bytes;
  }

  terminate() {
    if (!this.worker) return;
    this.worker.terminate();
    this.worker = null;
    const error = workerFailure("CSV Worker 已停止");
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }
}

let sharedService: CsvWorkerService | null = null;

export function getCsvWorkerService() {
  sharedService ??= new CsvWorkerService();
  return sharedService;
}
