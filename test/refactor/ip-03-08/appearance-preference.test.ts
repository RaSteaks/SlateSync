import { describe, expect, it } from "vitest";
import { vi } from "vitest";
import { cycleTheme, parseAppearancePreference, resolveTheme, themePreferenceLabel, watchSystemTheme } from "../../../src/renderer/services/appearance-preference";

describe("appearance preference", () => {
  it("hydrates supported values and sanitizes stale or corrupted data", () => {
    expect(parseAppearancePreference('{"theme":"light","density":"compact"}')).toEqual({ theme: "light", density: "compact" });
    expect(parseAppearancePreference('{"theme":"system","density":"comfortable"}')).toEqual({ theme: "system", density: "comfortable" });
    expect(parseAppearancePreference('{"theme":"sepia","density":"wide"}')).toEqual({ theme: "system", density: "comfortable" });
    expect(parseAppearancePreference("not-json")).toEqual({ theme: "system", density: "comfortable" });
  });

  it("resolves system appearance whenever the OS preference changes", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
    expect(resolveTheme("light", true)).toBe("light");
  });

  it("cycles the sidebar through the same preferences exposed in Global Settings", () => {
    expect(cycleTheme("system")).toBe("dark");
    expect(cycleTheme("dark")).toBe("light");
    expect(cycleTheme("light")).toBe("system");
    expect(themePreferenceLabel("system")).toBe("自动（跟随系统）");
  });

  it("subscribes to live system appearance changes and releases the listener", () => {
    let listener: ((event: MediaQueryListEvent) => void) | undefined;
    const media = {
      matches: false,
      addEventListener: vi.fn((_type: string, next: (event: MediaQueryListEvent) => void) => { listener = next; }),
      removeEventListener: vi.fn(),
    } as unknown as MediaQueryList;
    const onChange = vi.fn();

    const stopWatching = watchSystemTheme(media, onChange);
    expect(onChange).toHaveBeenCalledWith(false);
    listener?.({ matches: true } as MediaQueryListEvent);
    expect(onChange).toHaveBeenLastCalledWith(true);

    stopWatching();
    expect(media.removeEventListener).toHaveBeenCalledWith("change", expect.any(Function));
  });
});
