import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const shellStyles = new URL("../../../src/renderer/design-system/components.module.css", import.meta.url);
const designTokens = new URL("../../../src/renderer/design-system/tokens.css", import.meta.url);
const appStyles = new URL("../../../src/renderer/app/app.module.css", import.meta.url);
const appSource = new URL("../../../src/renderer/App.tsx", import.meta.url);

describe("application shell layout", () => {
  it("uses the packaged App Icon as the sidebar brand mark", async () => {
    const source = await readFile(appSource, "utf8");

    // Importing the canonical build asset lets Vite package the exact artwork
    // used by Electron instead of maintaining a second Renderer-only logo.
    expect(source).toContain('import appIconUrl from "../../build/icon.png"');
    expect(source).toContain("className={styles.brandIcon}");
    expect(source).toContain("src={appIconUrl}");
    expect(source).not.toContain('aria-hidden="true">S</span>');
  });

  it("uses the saved appearance preference for the sidebar theme control", async () => {
    const [source, css] = await Promise.all([
      readFile(appSource, "utf8"),
      readFile(appStyles, "utf8"),
    ]);

    // The control must show system/light/dark preference state itself, not
    // only the resolved color, so it stays in sync with Global Settings.
    expect(source).toContain('theme === "system"');
    expect(source).toContain("<Monitor size={16}");
    expect(source).toContain("cycleTheme(theme)");
    expect(source).toContain("onClick={() => setTheme(nextTheme)}");
    expect(source).toContain("styles.sidebarThemeButton");
    expect(source).toContain(">{themePreferenceLabel(theme)}</Button>");
    expect(source).toContain("<Icon icon={FolderKanban} size={18}");
    expect(css).toContain(".sidebarThemeButton");
    expect(css).toContain('data-collapsed="true"');
  });

  it("eases sidebar expansion and collapses motion while preserving reduced-motion support", async () => {
    const [shellCss, appCss] = await Promise.all([
      readFile(shellStyles, "utf8"),
      readFile(appStyles, "utf8"),
    ]);

    // Width and label visibility share one eased timeline; reduced-motion
    // remains an explicit opt-out for users who request no transitions.
    expect(shellCss).toContain("transition: grid-template-columns var(--ss-motion-slow) var(--ss-ease-in-out);");
    expect(shellCss).toMatch(/@media \(prefers-reduced-motion: reduce\) \{[\s\S]*\.appShell, \.brand \{ transition: none; \}/s);
    expect(appCss).toContain("transition: max-width var(--ss-motion-slow) var(--ss-ease-in-out)");
    expect(appCss).toContain('.navItem[data-collapsed="true"] span { max-width: 0;');
  });

  it("uses native typography and layered theme surfaces for the sidebar control", async () => {
    const [tokens, css] = await Promise.all([
      readFile(designTokens, "utf8"),
      readFile(appStyles, "utf8"),
    ]);

    // Keep the compact desktop UI aligned with macOS text metrics and ensure
    // the shortcut consumes semantic control tokens in both theme branches.
    expect(tokens).toContain('--ss-font-body: -apple-system, BlinkMacSystemFont, "SF Pro Text"');
    expect(tokens).toContain("--ss-color-control: #182231;");
    expect(tokens).toContain("--ss-color-surface-line: rgba(191, 207, 226, 0.08);");
    expect(tokens).toContain(':root[data-theme="light"]');
    expect(tokens).toContain("--ss-color-control: #e8eef4;");
    expect(tokens).toContain("--ss-color-surface-line: rgba(24, 35, 48, 0.08);");
    expect(tokens).toContain("--ss-nav-icon-size: 18px;");
    expect(tokens).toContain("--ss-nav-label-line-height: 1.35;");
    expect(css).toContain("font-family: var(--ss-font-body);");
    expect(css).toContain('.sidebarThemeButton[data-variant="ghost"] { color: var(--ss-color-ink-muted); background: transparent; }');
    expect(css).toContain(".navItem > svg { display: block; width: var(--ss-nav-icon-size);");
    expect(css).toContain("line-height: var(--ss-nav-label-line-height);");
  });

  it("pins the desktop sidebar footer independently from workspace scrolling", async () => {
    const css = await readFile(shellStyles, "utf8");

    // The sidebar itself stays in the viewport; only the middle navigation is
    // allowed to scroll, leaving the non-shrinking footer anchored at bottom.
    expect(css).toMatch(/\.sidebar \{[^}]*position: sticky;[^}]*height: 100vh;[^}]*overflow: hidden;/s);
    expect(css).toMatch(/\.sidebar nav \{[^}]*flex: 1 1 auto;[^}]*overflow-y: auto;/s);
    expect(css).toMatch(/\.sidebarFooter \{[^}]*flex: 0 0 auto;/s);
  });

  it("restores a natural-height top bar on narrow windows", async () => {
    const css = await readFile(shellStyles, "utf8");
    const narrowRules = css.match(/@media \(max-width: 640px\) \{([\s\S]*?)\n\}/)?.[1] || "";

    expect(narrowRules).toMatch(/\.sidebar \{[^}]*height: auto;[^}]*overflow: visible;/s);
    expect(narrowRules).toMatch(/\.sidebar nav \{[^}]*overflow: visible;/s);
  });

  it("separates the current project context from its navigation label", async () => {
    const [source, css] = await Promise.all([
      readFile(appSource, "utf8"),
      readFile(appStyles, "utf8"),
    ]);

    // The group label and project name form two deliberate rows; long names
    // keep the sidebar geometry stable while remaining available via title.
    expect(source).toContain("styles.navSectionCurrent");
    expect(source).toContain('className={styles.navSectionProject} title={project.name}');
    expect(css).toMatch(/\.navSection \{[^}]*margin: var\(--ss-space-5\) 0 var\(--ss-space-2\);/s);
    expect(css).toMatch(/\.navSectionCurrent \{[^}]*display: grid;[^}]*gap: var\(--ss-space-1\);/s);
    expect(css).toMatch(/\.navSectionProject \{[^}]*text-overflow: ellipsis;[^}]*white-space: nowrap;/s);
    // Responsive icon-only mode hides every text-bearing sidebar control,
    // including the theme label introduced for the expanded rail.
    expect(css).toMatch(/@media \(max-width: 920px\) \{[\s\S]*\.brandCopy, \.navSection, \.navItem span, \.sidebarThemeButton > span \{ display: none; \}/s);
  });
});
