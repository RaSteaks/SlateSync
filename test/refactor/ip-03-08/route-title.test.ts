import { describe, expect, it } from "vitest";
import type { Route } from "../../../src/renderer/state/types";
import { documentTitle, routeTitle } from "../../../src/renderer/app/route-title";

describe("route document titles", () => {
  it("keeps every supported route localized and namespaced", () => {
    const routes: Route[] = [
      "projects",
      "workspace",
      "project-settings",
      "global-settings",
      "logs",
      "help",
    ];
    expect(routes.map(routeTitle)).toEqual([
      "项目库",
      "工作台",
      "项目设置",
      "全局设置",
      "日志查看器",
      "说明",
    ]);
    expect(documentTitle("projects")).toBe("项目库 · SlateSync");
    expect(documentTitle("global-settings")).toBe("全局设置 · SlateSync");
  });
});

