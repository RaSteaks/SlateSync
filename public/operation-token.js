// Tiny latest-operation guard for renderer requests that cannot be cancelled.
// A completed request may commit UI state only while its token is still current.
export function createLatestOperation() {
  let current = 0;
  return {
    start() {
      current += 1;
      return current;
    },
    invalidate() {
      current += 1;
    },
    isCurrent(token) {
      return token === current;
    },
  };
}
