import { useEffect, useMemo, useRef, useState } from "react";
import type { ModelData } from "../../../shared/contracts/index.js";
import { getSlateSync, unwrap } from "../../services/api";
import { useProjectStore } from "../../state";

/** Provider identity and request generation both matter for A → B → A. The
 * render-time identity check also hides old options before the effect runs. */
export function useProviderModels(providerId: string) {
  const catalog = useProjectStore((state) => state.config?.models);
  const sequence = useRef(0);
  const [result, setResult] = useState<{ providerId: string; models: readonly ModelData[]; discovered: boolean } | null>(null);
  const fallback = useMemo(() => catalog?.filter((model) => model.providers.includes(providerId)) || [], [catalog, providerId]);
  useEffect(() => {
    const request = ++sequence.current;
    setResult(null);
    if (!providerId) return;
    void (async () => {
      try {
        const next = await unwrap(await getSlateSync().recognition.getModels({ providerId, forceRefresh: false }));
        if (sequence.current === request) setResult({ providerId, models: next.models, discovered: true });
      } catch {
        if (sequence.current === request) setResult({ providerId, models: fallback, discovered: false });
      }
    })();
    return () => { sequence.current += 1; };
  }, [fallback, providerId]);
  return result?.providerId === providerId ? result : { providerId, models: fallback, discovered: false };
}
