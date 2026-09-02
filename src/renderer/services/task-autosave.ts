import type { TaskData } from "../../shared/contracts/index.js";

type SaveState = "idle" | "dirty" | "saving" | "saved" | "error";
type PendingSnapshot = { readonly scope: number; readonly version: number; readonly task: TaskData };

/**
 * Serializes saves across task switches while retaining only the newest
 * immutable snapshot in the current scope. Reset invalidates UI ownership but
 * never forgets an in-flight writer, so a new task cannot create a second
 * concurrent save or receive the prior task's completion state.
 */
export function createTaskAutosave({ capture, save, onState, delayMs = 500 }: { capture: () => TaskData | null; save: (task: TaskData) => Promise<string | null | void>; onState: (state: SaveState) => void; delayMs?: number }) {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let scope = 0;
  let version = 0;
  let savedVersion = 0;
  let lastSavedTaskId: string | null = null;
  let worker: Promise<boolean> | null = null;
  let flushRequested = false;
  let pending: PendingSnapshot | null = null;

  const clearTimer = () => { if (timer) { clearTimeout(timer); timer = null; } };
  const report = (ownerScope: number, state: SaveState) => { if (ownerScope === scope) onState(state); };

  const run = async (flush: boolean): Promise<boolean> => {
    clearTimer();
    if (flush) flushRequested = true;
    if (!worker) {
      worker = (async () => {
        while (pending) {
          const target = pending;
          pending = null;
          report(target.scope, "saving");
          let savedTaskId: string | null | void;
          try {
            savedTaskId = await save(target.task);
          } catch {
            if (target.scope === scope) {
              pending = target;
              report(target.scope, "error");
            }
            flushRequested = false;
            return false;
          }
          if (target.scope === scope) {
            savedVersion = Math.max(savedVersion, target.version);
            // Keep the Main-assigned ID available to a recognition request even
            // when the Workspace route was unmounted during this save.
            lastSavedTaskId = typeof savedTaskId === "string" && savedTaskId ? savedTaskId : target.task.id || null;
            if (!pending) report(target.scope, "saved");
          }
          // An await above allows markDirty to enqueue a newer snapshot even
          // though control-flow analysis only sees the earlier null write.
          const queued = pending as PendingSnapshot | null;
          if (queued && !flushRequested) {
            report(queued.scope, "dirty");
            timer = setTimeout(() => { void run(false); }, delayMs);
            return true;
          }
        }
        flushRequested = false;
        return true;
      })().finally(() => { worker = null; });
    }
    return worker;
  };

  return {
    markDirty(snapshot?: TaskData | null) {
      const task = snapshot || capture();
      if (!task) return;
      version += 1;
      pending = { scope, version, task };
      onState("dirty");
      clearTimer();
      timer = setTimeout(() => { void run(false); }, delayMs);
    },
    flush: () => run(true),
    retry: () => run(true),
    reset() {
      clearTimer();
      scope += 1;
      version = 0;
      savedVersion = 0;
      lastSavedTaskId = null;
      flushRequested = false;
      pending = null;
      onState("idle");
    },
    // Consumers use this after flush() to bind work to the exact durable task
    // rather than relying on a route-owned activeId that may no longer exist.
    getLastSavedTaskId: () => lastSavedTaskId,
    hasPending: () => Boolean(pending || worker) || version !== savedVersion,
  };
}
