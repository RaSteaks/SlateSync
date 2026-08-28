import type { Density, Theme } from "../state";

export const APPEARANCE_PREFERENCE_KEY = "slatesync.appearance.v1";

const THEME_CYCLE: readonly Theme[] = ["system", "dark", "light"];

/**
 * The sidebar shortcut uses the same order as the Global Settings select so
 * either entry point can reach and persist every appearance preference.
 */
export function cycleTheme(theme: Theme): Theme {
  const currentIndex = THEME_CYCLE.indexOf(theme);
  return THEME_CYCLE[(currentIndex + 1) % THEME_CYCLE.length] || "system";
}

/** Keep the icon-only sidebar control's state and action text unambiguous. */
export function themePreferenceLabel(theme: Theme): string {
  return theme === "system" ? "自动（跟随系统）" : theme === "dark" ? "深色" : "浅色";
}

export function resolveTheme(theme: Theme, prefersDark: boolean): "dark" | "light" {
  return theme === "system" ? (prefersDark ? "dark" : "light") : theme;
}

export function watchSystemTheme(media: MediaQueryList, onChange: (prefersDark: boolean) => void): () => void {
  const sync = (event: MediaQueryListEvent | MediaQueryList) => onChange(event.matches);
  // Synchronize immediately as the OS can change between React's initial read
  // and effect subscription, then keep the app live-linked to later changes.
  sync(media);
  media.addEventListener("change", sync);
  return () => media.removeEventListener("change", sync);
}

export function parseAppearancePreference(raw: string | null): { readonly theme: Theme; readonly density: Density } {
  try {
    const value = JSON.parse(raw || "null") as { theme?: unknown; density?: unknown } | null;
    return {
      theme: value?.theme === "dark" || value?.theme === "light" ? value.theme : "system",
      density: value?.density === "compact" ? "compact" : "comfortable",
    };
  } catch {
    return { theme: "system", density: "comfortable" };
  }
}
