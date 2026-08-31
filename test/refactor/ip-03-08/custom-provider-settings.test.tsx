// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SlateSyncApi } from "../../../src/shared/contracts/index.js";
import { CustomProviderSettingsPanel } from "../../../src/renderer/features/settings/CustomProviderSettingsPanel";
import { useProjectStore, useUiStore } from "../../../src/renderer/state";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const mounted: Array<{ host: HTMLDivElement; root: Root }> = [];

afterEach(() => {
  for (const { host, root } of mounted.splice(0)) {
    act(() => root.unmount());
    host.remove();
  }
  useProjectStore.setState({ config: null, projects: [], current: null, scenarios: [], error: null });
  useUiStore.setState({ theme: "system", density: "comfortable", toast: null });
  Object.defineProperty(window, "slateSync", { configurable: true, value: undefined });
});

describe("custom provider discovery lifecycle", () => {
  it("ignores a late discovery response after switching providers", async () => {
    const providers = [
      provider("provider-a", "Provider A"),
      provider("provider-b", "Provider B"),
    ];
    const requests: Array<{ providerId: string; resolve: (result: unknown) => void }> = [];
    const api = {
      app: { getConfig: vi.fn(async () => ({ ok: true as const, data: null })) },
      settings: {
        listCustomProviders: vi.fn(async () => ({ ok: true as const, data: providers })),
      },
      recognition: {
        getModels: vi.fn(({ providerId }: { providerId: string }) => new Promise((resolve) => {
          requests.push({ providerId, resolve });
        })),
      },
    } as unknown as SlateSyncApi;
    Object.defineProperty(window, "slateSync", { configurable: true, value: api });

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    await act(async () => {
      root.render(<CustomProviderSettingsPanel />);
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(requests.map((request) => request.providerId)).toEqual(["provider-a"]);
    const providerBButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.includes("Provider B"));
    if (!(providerBButton instanceof HTMLButtonElement)) throw new Error("missing Provider B selector");
    await act(async () => {
      providerBButton.click();
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(requests.map((request) => request.providerId)).toEqual(["provider-a", "provider-b"]);

    await act(async () => {
      requests[0].resolve({ ok: true, data: discovery("provider-a", "model-a") });
      await Promise.resolve();
    });
    expect(host.textContent).not.toContain("model-a");

    await act(async () => {
      requests[1].resolve({ ok: true, data: discovery("provider-b", "model-b") });
      await Promise.resolve();
    });
    expect(host.textContent).toContain("model-b");
    expect(host.textContent).not.toContain("model-a");
  });

  it("keeps canceled models pending without selecting them by default", async () => {
    const providers = [provider("provider-a", "Provider A")];
    let resolveDiscovery: ((result: unknown) => void) | undefined;
    const api = {
      app: { getConfig: vi.fn(async () => ({ ok: true as const, data: null })) },
      settings: {
        listCustomProviders: vi.fn(async () => ({ ok: true as const, data: providers })),
      },
      recognition: {
        getModels: vi.fn(() => new Promise((resolve) => { resolveDiscovery = resolve; })),
      },
    } as unknown as SlateSyncApi;
    Object.defineProperty(window, "slateSync", { configurable: true, value: api });

    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    mounted.push({ host, root });
    await act(async () => {
      root.render(<CustomProviderSettingsPanel />);
      await Promise.resolve();
      await Promise.resolve();
    });

    await act(async () => {
      resolveDiscovery?.({
        ok: true,
        data: {
          ...discovery("provider-a", "unused"),
          models: [],
          pendingModels: [
            { id: "pending-model", apiId: "pending-model", label: "pending-model", providers: ["provider-a"], capabilityStatus: "pending" },
            { id: "canceled-model", apiId: "canceled-model", label: "canceled-model", providers: ["provider-a"], capabilityStatus: "canceled" },
          ],
          pendingModelCount: 2,
          statusCounts: { usable: 0, pending: 2, unsupported: 0, failed: 0 },
        },
      });
      await Promise.resolve();
    });

    const checks = [...host.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')];
    expect(checks).toHaveLength(2);
    expect(checks.map((input) => input.checked)).toEqual([true, false]);
  });
});

function provider(id: string, name: string) {
  return {
    id,
    name,
    label: name,
    baseUrl: "https://example.test/v1",
    transport: "chat-completions",
    jsonMode: "json_schema",
    imageDetail: "high",
    manualModelIds: [],
    revision: 1,
    keyConfigured: false,
  };
}

function discovery(providerId: string, modelId: string) {
  return {
    provider: providerId,
    source: "api",
    refreshedAt: "2026-08-31T00:00:00.000Z",
    availableModelCount: 1,
    visionModelCount: 1,
    fixedModelCount: 0,
    pendingModelCount: 0,
    failedModelCount: 0,
    models: [{
      id: modelId,
      label: modelId,
      description: "synthetic model",
      providers: [providerId],
      capabilityStatus: "declared",
    }],
    pendingModels: [],
    failedModels: [],
    unsupportedModels: [],
    statusCounts: { usable: 1, pending: 0, unsupported: 0, failed: 0 },
  };
}
