import { Surface } from "../../design-system";
import { useGlobalSettingsStore } from "../../state";
import type { GlobalSettingKey } from "../../../shared/contracts/index.js";
import { PADDLE_ADVANCED_KEYS, VISION_ADVANCED_KEYS } from "./globalSettingsModel";
import styles from "../../app/app.module.css";

export const SETTINGS_SECTIONS = [
  { id: "settings-general", index: "01", label: "密钥与外观" },
  { id: "settings-custom-providers", index: "02", label: "自定义接口" },
  { id: "settings-ocr", index: "03", label: "本地 OCR" },
  { id: "settings-runtime", index: "04", label: "运行参数" },
] as const;

// Keys that can turn dirty inside each section; the custom-provider section
// edits its own registry API instead of global settings values, so it never
// carries a marker.
const SECTION_DIRTY_KEYS: Record<(typeof SETTINGS_SECTIONS)[number]["id"], readonly GlobalSettingKey[] | null> = {
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

function SectionTocLink({ id, index, label }: { id: string; index: string; label: string }) {
  const keys = SECTION_DIRTY_KEYS[id as keyof typeof SECTION_DIRTY_KEYS];
  // Primitive boolean selector: the link re-renders only when its marker
  // appears or disappears, not on every keystroke elsewhere.
  const dirty = useGlobalSettingsStore((state) => (keys ? keys.some((key) => state.dirtyKeys.has(key)) : false));
  return <a className={styles.helpTocLink} href={`#${id}`} data-dirty={dirty || undefined}><span>{index}</span>{label}</a>;
}

/** Sticky in-page directory for the settings sections (help-page pattern). */
export function GlobalSettingsSectionNav() {
  return <aside className={styles.helpAside}>
    <Surface as="nav" className={`${styles.panel} ${styles.helpToc}`} aria-label="设置目录">
      <p className={styles.kicker}>设置目录</p>
      <div className={styles.helpTocList}>
        {SETTINGS_SECTIONS.map((section) => <SectionTocLink key={section.id} {...section} />)}
      </div>
    </Surface>
  </aside>;
}
