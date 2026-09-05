import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useSettingsStore, useUiStore } from "../../state";
import { validateProjectName } from "../../validation/input-validation";

/** One immutable save owns both the page button and the shell leave guard. */
export async function saveProjectSettingsChanges(): Promise<boolean> {
  const { projectId, draft, saving } = useSettingsStore.getState();
  const project = useProjectStore.getState().current;
  if (saving || !draft || !projectId || project?.id !== projectId || project.archivedAt) return false;
  const validation = validateProjectName(draft.name);
  if (!validation.ok) {
    useSettingsStore.setState({ saveError: validation.message });
    return false;
  }
  const snapshot = structuredClone(draft);
  useSettingsStore.setState({ saving: true, saveError: null });
  try {
    const updated = await unwrap(await getSlateSync().projects.update({ id: projectId, name: snapshot.name.trim(), description: snapshot.description.trim(), settings: snapshot.settings }));
    if (useSettingsStore.getState().projectId !== projectId || useProjectStore.getState().current?.id !== projectId) return false;
    const baseline = { name: updated.name, description: updated.description, settings: updated.settings || snapshot.settings };
    useSettingsStore.setState({ baseline, draft: structuredClone(baseline), dirty: false });
    useProjectStore.getState().setCurrent(updated);
    useProjectStore.getState().setProjects(useProjectStore.getState().projects.map((item) => item.id === updated.id ? updated : item));
    useUiStore.getState().setToast({ tone: "success", message: "项目设置已保存" });
    return true;
  } catch (error) {
    if (useSettingsStore.getState().projectId === projectId) useSettingsStore.setState({ saveError: appErrorFromUnknown(error).message });
    return false;
  } finally {
    if (useSettingsStore.getState().projectId === projectId) useSettingsStore.setState({ saving: false });
  }
}
