import { useRecognitionStore, useTaskStore, type WorkspaceOperationKind } from "../state";

export function isWorkspaceBusy(): boolean {
  return Boolean(useTaskStore.getState().operation || useRecognitionStore.getState().running);
}

export function isRecognitionBusy(): boolean {
  return useRecognitionStore.getState().running || useTaskStore.getState().operation?.kind === "recognition";
}

/** A cancel request can outlive run(). Retaining the lease keeps task actions
 * blocked until both promises finish; old owners cannot release a newer lease. */
export function acquireWorkspaceOperation(kind: WorkspaceOperationKind, projectId: string) {
  const id = useTaskStore.getState().beginOperation(kind, projectId);
  if (id === null) return null;
  let owners = 1;
  return {
    isCurrent: () => useTaskStore.getState().operation?.id === id,
    retain: () => { owners += 1; },
    release: () => {
      owners -= 1;
      if (owners === 0) useTaskStore.getState().endOperation(id);
    },
  };
}
