// Pure state helpers for the legacy custom-provider panel.
// Keeping selection/probe transitions outside the DOM renderer makes stale
// response behavior testable without exposing Main-process credentials.

export function defaultPendingSelection(models = []) {
  return (models || [])
    .filter((model) => model?.capabilityStatus !== "canceled")
    .map((model) => model.apiId || model.id)
    .filter(Boolean);
}

export function mergeCustomProviderDiscovery(previous = {}, next = {}) {
  const pendingModels = Array.isArray(next.pendingModels) ? next.pendingModels : [];
  const pendingById = new Map(pendingModels.map((model) => [model.apiId || model.id, model]));
  const selectedPending = Array.isArray(previous.selectedPending)
    ? previous.selectedPending.filter((modelId) =>
      pendingById.has(modelId) && pendingById.get(modelId)?.capabilityStatus !== "canceled",
    )
    : defaultPendingSelection(pendingModels);
  // Server refreshes replace model data but retain the user's local search and
  // explicit checkbox choices, including after a probe completes.
  return { ...previous, ...next, selectedPending };
}

export function clearCustomProviderProbeState(discovery = {}) {
  return {
    ...discovery,
    probing: false,
    progress: null,
  };
}
