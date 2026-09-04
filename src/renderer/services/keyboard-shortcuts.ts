export const RECOGNITION_SHORTCUT_EVENT = "slatesync:recognize";
// Shell-dispatched save request for the Global Settings page; mirrors the
// recognition event so the page owns the concrete save orchestration.
export const GLOBAL_SETTINGS_SAVE_EVENT = "slatesync:save-global-settings";

export function isEditableShortcutTarget(target: EventTarget | null): boolean {
  return target instanceof HTMLElement
    && target.matches("input, textarea, select, button, [contenteditable='true']");
}
