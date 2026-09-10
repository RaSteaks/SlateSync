import type { GlobalSettingsPatch } from "../../../shared/contracts/index.js";
import { appErrorFromUnknown, getSlateSync, requireGlobalSettingsApi, unwrap } from "../../services/api";
import { useGlobalSettingsStore, useProjectStore, useSettingsStore, useUiStore, type Route } from "../../state";
import { GLOBAL_NUMERIC_RANGES, GLOBAL_TIMEOUT_RANGES, validateGlobalSettingValue } from "../../validation/global-settings-validation";

/** Dirty drafts live in a module store, so any shell surface can read them. */
export function isGlobalSettingsDirty(): boolean {
  return useGlobalSettingsStore.getState().dirtyKeys.size > 0;
}

/**
 * Route-change gate for either settings draft. Navigating inside the
 * page (including the Cmd+, shortcut to the current route) never blocks; any
 * detour away from the page while dirty does.
 */
export function isRouteChangeBlocked(current: Route, next: Route): boolean {
  if (current === next) return false;
  if (current === "project-settings") {
    const state = useSettingsStore.getState();
    return state.dirty || state.saving;
  }
  return current === "global-settings" && (isGlobalSettingsDirty() || useGlobalSettingsStore.getState().saveState === "saving");
}

/** Re-validate every dirty numeric field; returns the invalid count. */
export function validateDirtyNumericFields(): number {
  const { dirtyKeys, draftValues, saved } = useGlobalSettingsStore.getState();
  let invalid = 0;
  for (const key of dirtyKeys) {
    if (!(key in GLOBAL_NUMERIC_RANGES) && !(key in GLOBAL_TIMEOUT_RANGES)) continue;
    const value = draftValues[key] ?? saved?.values[key] ?? "";
    const result = validateGlobalSettingValue(key, value);
    if (!result.ok) {
      invalid += 1;
      useGlobalSettingsStore.getState().setFieldError(key, result.message);
    }
  }
  return invalid;
}

/**
 * The single save entry for global settings: page header button, Cmd+S, and
 * the App leave-guard dialog all route through here. `reset` restores the
 * environment defaults instead of submitting the dirty patch. Resolves to
 * false (with store state/toast describing the failure) when the save did
 * not complete, so callers can keep their dialog or route open.
 */
export async function saveGlobalSettingsChanges(reset = false): Promise<boolean> {
  const store = useGlobalSettingsStore.getState();
  if (store.saveState === "saving") return false;
  if (!reset) {
    const invalidCount = validateDirtyNumericFields();
    if (invalidCount > 0) {
      useUiStore.getState().setToast({ tone: "warning", message: `请先修正 ${invalidCount} 个无效的数值` });
      return false;
    }
  }
  if (!store.beginMutation("global")) {
    useUiStore.getState().setToast({ tone: "warning", message: "配置正在写入，请等待当前操作完成。" });
    return false;
  }
  store.setSaveState("saving");
  store.setSaveError(null);
  try {
    const api = requireGlobalSettingsApi();
    if (reset) {
      const saved = await unwrap(await api.settings.saveGlobalSettings({ reset: true }));
      useGlobalSettingsStore.getState().adoptServerSnapshot(saved);
    } else {
      const { draftValues, dirtyKeys } = useGlobalSettingsStore.getState();
      // `draftValues` only holds keys that differ from the saved snapshot, so
      // the patch can never turn inherited defaults into stored overrides.
      const patch = Object.fromEntries(
        [...dirtyKeys].map((key) => [key, draftValues[key] ?? ""]),
      ) as GlobalSettingsPatch;
      const saved = await unwrap(await api.settings.saveGlobalSettings({ values: patch }));
      useGlobalSettingsStore.getState().adoptServerSnapshot(saved);
    }
    // Persistence is already committed. A capability refresh failure must not
    // suggest that retrying the write is necessary or resurrect old drafts.
    const refreshed = await refreshSettingsConfig();
    const result = useGlobalSettingsStore.getState().saved;
    useGlobalSettingsStore.getState().setSaveState("saved");
    useUiStore.getState().setToast({
      tone: refreshed ? "success" : "warning",
      message: !refreshed ? "全局配置已保存；运行配置刷新失败，请稍后重新打开应用。" : result?.restartRequired
        ? "全局配置已保存；工作流路径将在下次启动生效"
        : reset
          ? "已恢复 .env 与内置默认值"
          : "全局配置已保存",
    });
    return true;
  } catch (error) {
    useGlobalSettingsStore.getState().setSaveState("error");
    useGlobalSettingsStore.getState().setSaveError(appErrorFromUnknown(error).message);
    return false;
  } finally { useGlobalSettingsStore.getState().endMutation("global"); }
}

export async function refreshSettingsConfig(): Promise<boolean> {
  try {
    useProjectStore.getState().setConfig(await unwrap(await getSlateSync().app.getConfig()));
    return true;
  } catch { return false; }
}
