// @vitest-environment jsdom
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { useProviderModels } from "../../../src/renderer/features/recognition/useProviderModels";
import { useProjectStore } from "../../../src/renderer/state";
import type { ConfigData } from "../../../src/shared/contracts/index.js";
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const mounted: Array<{ root: ReturnType<typeof createRoot>; host: HTMLDivElement }> = [];
afterEach(() => {
  for (const { root, host } of mounted.splice(0)) { act(() => root.unmount()); host.remove(); }
  useProjectStore.setState({ config: null });
});

it("uses current-provider fallbacks and rejects old A → B → A responses", async () => {
  const requests: Array<{ providerId: string; resolve: (value: unknown) => void; reject: (reason: Error) => void }> = [];
  Object.defineProperty(window, "slateSync", { configurable: true, value: { recognition: {
    getModels: vi.fn(({ providerId }) => new Promise((resolve, reject) => requests.push({ providerId, resolve, reject }))),
  } } });
  useProjectStore.setState({ config: { models: [{ id: "fallback-a", providers: ["a"] }, { id: "fallback-b", providers: ["b"] }] } as unknown as ConfigData });
  function Harness({ providerId }: { providerId: string }) {
    const { models } = useProviderModels(providerId);
    return <output>{models.map(model => model.id).join(",")}</output>;
  }
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host); mounted.push({ root, host });
  for (const providerId of ["a", "b", "a"]) {
    await act(async () => { root.render(<Harness providerId={providerId} />); });
    expect(host.textContent).toBe(`fallback-${providerId}`);
  }
  await act(async () => { requests[2].resolve({ ok: true, data: { models: [{ id: "new-a", providers: ["a"] }] } }); });
  await act(async () => {
    requests[0].resolve({ ok: true, data: { models: [{ id: "old-a", providers: ["a"] }] } });
    requests[1].reject(new Error("late b failure"));
  });
  expect(host.textContent).toBe("new-a");
  await act(async () => { root.render(<Harness providerId="b" />); });
  act(() => root.unmount()); mounted.pop(); host.remove();
  // A settled request from an unmounted consumer has no projection owner.
  await act(async () => { requests[3].resolve({ ok: true, data: { models: [] } }); });
});
