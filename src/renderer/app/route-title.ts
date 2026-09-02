import type { Route } from "../state/types";

const ROUTE_TITLES: Record<Route, string> = {
  projects: "项目库",
  workspace: "工作台",
  "project-settings": "项目设置",
  "global-settings": "全局设置",
  logs: "日志查看器",
  help: "说明",
};

export function routeTitle(route: Route): string {
  return ROUTE_TITLES[route];
}

// Keep the native window title route-scoped. The toolbar already carries
// project context, while putting it here could leave a stale name on Library.
export function documentTitle(route: Route): string {
  return `${routeTitle(route)} · SlateSync`;
}

