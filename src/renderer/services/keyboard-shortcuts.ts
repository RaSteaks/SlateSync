export const RECOGNITION_SHORTCUT_EVENT = "slatesync:recognize";

export function isEditableShortcutTarget(target: EventTarget | null): boolean {
  return target instanceof HTMLElement
    && target.matches("input, textarea, select, button, [contenteditable='true']");
}
