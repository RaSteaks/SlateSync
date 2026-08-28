import { useCallback, useState } from "react";

export interface RecognitionDraft {
  readonly providerId: string;
  readonly modelId: string;
  readonly accuracyMode: "high" | "standard";
  readonly scenarioId: string;
  readonly customPrompt: string;
}

const EMPTY_DRAFT: RecognitionDraft = {
  providerId: "",
  modelId: "",
  accuracyMode: "high",
  scenarioId: "",
  customPrompt: "",
};

/** Keeps recognition controls as one draft instead of five unrelated states. */
export function useRecognitionDraft() {
  const [draft, setDraft] = useState<RecognitionDraft>(EMPTY_DRAFT);
  const [dirty, setDirty] = useState(false);
  const replace = useCallback((next: RecognitionDraft) => {
    setDraft(next);
    setDirty(false);
  }, []);
  const patch = useCallback((next: Partial<RecognitionDraft>) => {
    setDraft((current) => ({ ...current, ...next }));
    setDirty(true);
  }, []);
  const setModelFallback = useCallback((modelId: string) => {
    setDraft((current) => current.modelId || !modelId ? current : { ...current, modelId });
  }, []);
  const markClean = useCallback(() => setDirty(false), []);
  return { draft, dirty, replace, patch, setModelFallback, markClean } as const;
}
