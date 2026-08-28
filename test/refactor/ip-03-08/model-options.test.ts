import { describe, expect, it } from "vitest";
import type { ModelData } from "../../../src/shared/contracts/index.js";
import { groupModelOptions } from "../../../src/renderer/features/recognition/model-options";

function model(id: string, options: Partial<ModelData> = {}): ModelData {
  return {
    id,
    label: id,
    description: "",
    providers: ["openrouter"],
    ...options,
  };
}

describe("OpenRouter model option groups", () => {
  it("keeps curated recommendations and fills the primary group to ten", () => {
    const models = [
      model("qwen/qwen3.7-flash", { fixed: true, vendor: "qwen" }),
      model("openai/gpt-4o-mini", { fixed: true, vendor: "openai" }),
      ...Array.from({ length: 11 }, (_, index) => model(`vendor/model-${index + 1}`, {
        fixed: false,
        vendor: index < 10 ? "vendor-a" : "vendor-b",
      })),
    ];

    const groups = groupModelOptions("openrouter", models);
    expect(groups[0]?.label).toBe("推荐模型 · 优先 10 个");
    expect(groups[0]?.models).toHaveLength(10);
    expect(groups[0]?.models.slice(0, 2).map((item) => item.id)).toEqual([
      "qwen/qwen3.7-flash",
      "openai/gpt-4o-mini",
    ]);
    expect(groups.map((group) => group.label)).toEqual([
      "推荐模型 · 优先 10 个",
      "Vendor A · 其余 2 个",
      "Vendor B · 其余 1 个",
    ]);
  });

  it("keeps non-OpenRouter providers in one flat group", () => {
    const groups = groupModelOptions("openai-compatible", [model("local-vision")]);
    expect(groups).toHaveLength(1);
    expect(groups[0]?.models.map((item) => item.id)).toEqual(["local-vision"]);
  });
});
