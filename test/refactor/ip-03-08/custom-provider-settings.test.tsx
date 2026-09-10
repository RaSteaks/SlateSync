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
    // The registry/detail split is part of the renderer contract, not just a
    // visual arrangement: the selected provider must expose its state to
    // keyboard and assistive-technology users before discovery resolves.
    expect(host.querySelector('[role="list"][aria-label="已注册接口列表"]')).not.toBeNull();
    const providerBButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.includes("Provider B"));
    if (!(providerBButton instanceof HTMLButtonElement)) throw new Error("missing Provider B selector");
    const providerAButton = [...host.querySelectorAll("button")].find((button) => button.textContent?.includes("Provider A"));
    if (!(providerAButton instanceof HTMLButtonElement)) throw new Error("missing Provider A selector");
    expect(providerAButton.getAttribute("aria-pressed")).toBe("true");
    expect(host.textContent).toContain("检测模型列表");
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

it("keeps raw model text and modal errors across failed saves, and prevents duplicate submits", async () => {
  const pending: Array<(value: unknown) => void> = [];
  const create = vi.fn(() => new Promise(resolve => pending.push(resolve)));
  Object.defineProperty(window, "slateSync", { configurable: true, value: {
    app: { getConfig: async () => ({ ok: true, data: null }) },
    settings: { listCustomProviders: async () => ({ ok: true, data: [] }), createCustomProvider: create },
    recognition: { getModels: async () => ({ ok: true, data: discovery("created", "model") }) },
  } });
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host); mounted.push({ host, root });
  await act(async () => { root.render(<CustomProviderSettingsPanel />); });
  const newButton = [...host.querySelectorAll("button")].find(button => button.textContent === "新增")!;
  act(() => newButton.click());
  const form = document.querySelector<HTMLFormElement>("#custom-provider-form")!;
  const textarea = form.querySelector("textarea")!;
  const type = (value: string) => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, value);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  };
  act(() => type("vendor/one\n"));
  expect(textarea.value).toBe("vendor/one\n");
  act(() => type("vendor/one\nvendor/two, vendor/three\n"));
  act(() => { form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); });
  expect(create).toHaveBeenCalledTimes(1);
  expect(create.mock.calls[0][0].manualModelIds).toEqual(["vendor/one", "vendor/two", "vendor/three"]);
  expect(textarea.disabled).toBe(true);
  act(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", cancelable: true })));
  expect(document.querySelector("#custom-provider-form")).not.toBeNull();
  await act(async () => { pending[0]({ ok: false, error: { code: "TEST", message: "接口请求失败" } }); });
  expect(document.querySelector('[role="dialog"] [role="alert"]')?.textContent).toContain("接口请求失败");
  expect(textarea.value).toBe("vendor/one\nvendor/two, vendor/three\n");
  expect(textarea.disabled).toBe(false);
  act(() => form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  await act(async () => { pending[1]({ ok: true, data: provider("created", "新增接口") }); });
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  // A fresh editor compares the raw textarea against its opening baseline.
  act(() => { newButton.focus(); newButton.click(); });
  const reopened = document.querySelector<HTMLTextAreaElement>("#custom-provider-form textarea")!;
  const replaceText = (value: string) => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(reopened, value);
    reopened.dispatchEvent(new Event("input", { bubbles: true }));
  };
  act(() => replaceText("\n\n"));
  act(() => replaceText(""));
  act(() => [...document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find(button => button.textContent === "取消")!.click());
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  expect(document.activeElement).toBe(newButton);
});

it("keeps a failed provider deletion in its dialog and allows one retry", async () => {
  const pending: Array<(result: unknown) => void> = [];
  const remove = vi.fn(() => new Promise(resolve => pending.push(resolve)));
  Object.defineProperty(window, "slateSync", { configurable: true, value: {
    app: { getConfig: async () => ({ ok: true, data: null }) },
    settings: { listCustomProviders: async () => ({ ok: true, data: [provider("a", "接口 A")] }), deleteCustomProvider: remove },
    recognition: { getModels: async () => ({ ok: true, data: discovery("a", "model") }) },
  } });
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host); mounted.push({ host, root });
  await act(async () => { root.render(<CustomProviderSettingsPanel />); });
  const button = (text: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find(candidate => candidate.textContent === text)!;
  act(() => button("删除").click());
  act(() => { button("确认删除").click(); button("确认删除").click(); });
  expect(remove).toHaveBeenCalledTimes(1);
  expect(button("取消").disabled).toBe(true);
  await act(async () => pending[0]({ ok: false, error: { code: "TEST", message: "模拟删除失败" } }));
  expect(document.querySelector('[role="dialog"] [role="alert"]')?.textContent).toContain("模拟删除失败");
  expect(button("取消").disabled).toBe(false);
  act(() => button("确认删除").click());
  expect(document.querySelector('[role="dialog"] [role="alert"]')).toBeNull();
  await act(async () => pending[1]({ ok: true, data: { deleted: "a" } }));
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});
