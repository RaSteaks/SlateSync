import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

const shellStyles = new URL("../../../src/renderer/design-system/components.module.css", import.meta.url);
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
    expect(css).toMatch(/@media \(max-width: 920px\) \{[\s\S]*\.navSection, \.navItem span \{ display: none; \}/s);
  });
});
