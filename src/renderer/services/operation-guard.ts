/** Monotonic guards protect UI state when the frozen IPC API cannot cancel work. */
export function createOperationGuard() {
  let current = 0;
  return {
    start() { current += 1; return current; },
    invalidate() { current += 1; },
    isCurrent(token: number) { return token === current; },
  };
}
