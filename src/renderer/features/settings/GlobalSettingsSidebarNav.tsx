import { useGlobalSettingsStore, type SettingsSectionId } from "../../state";
import type { GlobalSettingKey } from "../../../shared/contracts/index.js";
import { PADDLE_ADVANCED_KEYS, VISION_ADVANCED_KEYS } from "./globalSettingsModel";
import styles from "../../app/app.module.css";

export const SETTINGS_SECTIONS: ReadonlyArray<{ id: SettingsSectionId; label: string }> = [
  { id: "settings-general", label: "密钥与外观" },
  { id: "settings-custom-providers", label: "自定义接口" },
  { id: "settings-ocr", label: "本地 OCR" },
  { id: "settings-runtime", label: "运行参数" },
];

// Keys that can turn dirty inside each section; the custom-provider section
// edits its own registry API instead of global settings values, so it never
// carries a marker.
const SECTION_DIRTY_KEYS: Record<SettingsSectionId, readonly GlobalSettingKey[] | null> = {
  "settings-general": [
    "OPENAI_BASE_URL",
    "OPENROUTER_BASE_URL",
    "OPENROUTER_SITE_URL",
    "TOKENPLAN_BASE_URL",
    "DASHSCOPE_BASE_URL",
    "OPENAI_COMPATIBLE_BASE_URL",
    "OPENAI_COMPATIBLE_MODEL",
    "OPENAI_COMPATIBLE_API_MODE",
    "OPENAI_COMPATIBLE_JSON_MODE",
    "OPENAI_COMPATIBLE_IMAGE_DETAIL",
  ],
  "settings-custom-providers": null,
  "settings-ocr": [...VISION_ADVANCED_KEYS, ...PADDLE_ADVANCED_KEYS],
  "settings-runtime": [
    "MAX_BODY_MB",
    "MODEL_REQUEST_TIMEOUT_MS",
    "MODEL_REQUEST_MAX_RETRIES",
    "MODEL_PAGE_CONCURRENCY",
    "MAX_CONCURRENT_RECOGNITIONS",
    "SLATESYNC_CONFIG_PATH",
    "PADDLE_PDX_CACHE_HOME",
  ],
};

function SettingsSubNavItem({ id, label, active, onSelect }: { id: SettingsSectionId; label: string; active: boolean; onSelect: (id: SettingsSectionId) => void }) {
  const keys = SECTION_DIRTY_KEYS[id];
  // Primitive boolean selector: the item re-renders only when its dirty
  // marker appears or disappears, not on every keystroke elsewhere.
  const dirty = useGlobalSettingsStore((state) => (keys ? keys.some((key) => state.dirtyKeys.has(key)) : false));
  return <button
    type="button"
    className={styles.navSubItem}
    data-active={active}
    data-dirty={dirty || undefined}
    onClick={() => onSelect(id)}
  ><span>{label}</span></button>;
}

/**
 * Global-settings sections as a dropdown sub-list under the sidebar's
 * 全局设置 item. The shell mounts it only while that route is active;
 * selecting an item scrolls the page to the section (the shell owns the
 * scroll), and a warning dot marks sections with unsaved drafts.
 */
export function GlobalSettingsSidebarNav({ activeSection, onSelect }: { activeSection: SettingsSectionId | null; onSelect: (id: SettingsSectionId) => void }) {
  return <div className={styles.navSubList} role="group" aria-label="全局设置分区导航">
    {SETTINGS_SECTIONS.map((section) => (
      <SettingsSubNavItem
        key={section.id}
        id={section.id}
        label={section.label}
        active={activeSection === section.id}
        onSelect={onSelect}
      />
    ))}
  </div>;
}
