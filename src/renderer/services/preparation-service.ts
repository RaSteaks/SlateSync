import type { AppError } from "../../shared/contracts/index.js";

interface PreparationResult {
  readonly pageCount: number;
  readonly imageDataGroups: readonly (readonly string[])[];
}

interface Pending {
  resolve(value: PreparationResult | readonly (readonly string[])[]): void;
  reject(error: Error): void;
  onProgress(progress: number, message: string): void;
  lastProgressAt: number;
  deferredProgress: { progress: number; message: string } | null;
  progressTimer: ReturnType<typeof setTimeout> | null;
}

/** Worker-owned image/PDF rasterization keeps canvas and PDF work out of React. */
export class PreparationService {
  private worker: Worker | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();

  private ensureWorker() {
    if (this.worker) return this.worker;
    this.worker = new Worker(new URL("../workers/preparation.worker.ts", import.meta.url), { type: "module" });
    this.worker.addEventListener("message", (event: MessageEvent<{ id: number; type: string; progress?: number; message?: string; pageCount?: number; imageDataGroups?: string[][] }>) => {
      const message = event.data;
      const request = this.pending.get(message.id);
      if (!request) return;
      if (message.type === "progress") this.queueProgress(message.id, request, message.progress || 0, message.message || "正在准备素材");
      else if (message.type === "result") { this.finishRequest(message.id, request); request.resolve({ pageCount: message.pageCount || 0, imageDataGroups: message.imageDataGroups || [] }); }
      else if (message.type === "recompressed") { this.finishRequest(message.id, request); request.resolve(message.imageDataGroups || []); }
      else { this.finishRequest(message.id, request); request.reject(new Error(message.message || "场记单准备失败")); }
    });
    this.worker.addEventListener("error", () => this.failWorker("场记单准备 Worker 不可用"));
    return this.worker;
  }

  private queueProgress(id: number, request: Pending, progress: number, message: string) {
    const now = performance.now();
    const remaining = 100 - (now - request.lastProgressAt);
    if (remaining <= 0 && !request.progressTimer) {
      request.lastProgressAt = now;
      request.onProgress(progress, message);
      return;
    }
    request.deferredProgress = { progress, message };
    if (request.progressTimer) return;
    request.progressTimer = setTimeout(() => {
      request.progressTimer = null;
      if (!this.pending.has(id) || !request.deferredProgress) return;
      const deferred = request.deferredProgress;
      request.deferredProgress = null;
      request.lastProgressAt = performance.now();
      request.onProgress(deferred.progress, deferred.message);
    }, Math.max(0, remaining));
  }

  private finishRequest(id: number, request: Pending) {
    if (request.progressTimer) clearTimeout(request.progressTimer);
    request.progressTimer = null;
    request.deferredProgress = null;
    this.pending.delete(id);
  }

  private failWorker(message: string) {
    this.worker?.terminate();
    this.worker = null;
    const error = new Error(message);
    for (const [id, request] of this.pending) { this.finishRequest(id, request); request.reject(error); }
    this.pending.clear();
  }

  prepare(file: File, onProgress: (progress: number, message: string) => void): Promise<PreparationResult> {
    const worker = this.ensureWorker();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as Pending["resolve"], reject, onProgress, lastProgressAt: Number.NEGATIVE_INFINITY, deferredProgress: null, progressTimer: null });
      void file.arrayBuffer().then((data) => {
        if (!this.pending.has(id)) return;
        worker.postMessage({ id, fileType: file.type || "image/jpeg", data, filename: file.name }, [data]);
      }).catch((error: unknown) => {
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("无法读取场记单"));
      });
    });
  }

  recompress(imageDataGroups: readonly (readonly string[])[], profile: { readonly maxDimension: number; readonly quality: number }, onProgress: (progress: number, message: string) => void): Promise<readonly (readonly string[])[]> {
    const worker = this.ensureWorker();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as Pending["resolve"], reject, onProgress, lastProgressAt: Number.NEGATIVE_INFINITY, deferredProgress: null, progressTimer: null });
      // Clone before posting because task snapshots and preview state retain
      // ownership of their immutable groups while compression is in flight.
      worker.postMessage({ id, type: "recompress", imageDataGroups: imageDataGroups.map((group) => [...group]), ...profile });
    });
  }

  terminate() {
    this.worker?.terminate();
    this.worker = null;
    const error = new Error("场记单准备已停止");
    for (const [id, request] of this.pending) { this.finishRequest(id, request); request.reject(error); }
    this.pending.clear();
  }
}

export function asPreparationError(error: unknown): AppError {
  return { code: "PREPARATION_FAILED", message: error instanceof Error ? error.message : "无法准备场记单", retryable: true };
}

let service: PreparationService | null = null;
export function getPreparationService() {
  service ??= new PreparationService();
  return service;
}
