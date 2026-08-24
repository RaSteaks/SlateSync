import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { describe, expect, it } from "vitest";
import {
  isAllowedRendererDevNavigation,
  parseRendererDevUrl,
} from "../../../electron/renderer-dev-url.mjs";

const repositoryRoot = new URL("../../../", import.meta.url);

describe("Electron Renderer development composition", () => {
  it("accepts only unauthenticated loopback HTTP Renderer URLs", () => {
    expect(parseRendererDevUrl("http://localhost:5173")).toEqual({
      href: "http://localhost:5173/",
      origin: "http://localhost:5173",
    });
    expect(parseRendererDevUrl("http://127.0.0.1:5173/app")).not.toBeNull();
    expect(parseRendererDevUrl("http://[::1]:5173/app")).not.toBeNull();

    expect(parseRendererDevUrl("https://localhost:5173")).toBeNull();
    expect(parseRendererDevUrl("http://renderer.example:5173")).toBeNull();
    expect(parseRendererDevUrl("http://localhost.example:5173")).toBeNull();
    expect(parseRendererDevUrl("http://user:secret@localhost:5173")).toBeNull();
  });

  it("keeps navigation and redirects on the configured loopback origin", () => {
    const origin = "http://localhost:5173";

    expect(isAllowedRendererDevNavigation("http://localhost:5173/projects/1", origin)).toBe(true);
    expect(isAllowedRendererDevNavigation("http://localhost:5174/", origin)).toBe(false);
    expect(isAllowedRendererDevNavigation("http://renderer.example:5173/", origin)).toBe(false);
  });

  it("guards both Renderer navigation and HTTP redirects in Electron", async () => {
    const source = await readFile(
      new URL("electron/main.mjs", repositoryRoot),
      "utf8",
    );

    // Both events share one guard so a local Vite response cannot redirect the
    // typed Preload gateway onto an untrusted remote page.
    expect(source).toContain('on("will-navigate", guardRendererNavigation)');
    expect(source).toContain('on("will-redirect", guardRendererNavigation)');
  });

  it("starts Vite with the target-specific Renderer config", async () => {
    const source = await readFile(
      new URL("scripts/electron-dev.mjs", repositoryRoot),
      "utf8",
    );

    // SlateSync has no root vite.config.ts, so an implicit Vite launch serves
    // the repository directory and Electron displays a blank page.
    expect(source).toContain(
      'const viteConfig = resolve(projectRoot, "vite.renderer.config.ts")',
    );
    expect(source).toContain('[viteCli, "--config", viteConfig]');
  });

  it("keeps the dev URL and Renderer mode in the shared child environment", async () => {
    const source = await readFile(
      new URL("scripts/electron-dev.mjs", repositoryRoot),
      "utf8",
    );

    expect(source).toContain('SLATESYNC_RENDERER_DEV: "true"');
    expect(source).toContain("SLATESYNC_RENDERER_URL: rendererUrl");
    expect(source).toContain("env: childEnv");
  });

  it("transforms the Renderer HTML for React Refresh without weakening production", async () => {
    const previousDevMode = process.env.SLATESYNC_RENDERER_DEV;
    process.env.SLATESYNC_RENDERER_DEV = "true";
    const server = await createServer({
      configFile: fileURLToPath(
        new URL("vite.renderer.config.ts", repositoryRoot),
      ),
      logLevel: "silent",
    });

    try {
      // Transforming without listen() exercises the exact Vite HTML pipeline
      // used by Electron while keeping this regression test headless.
      const source = await readFile(
        new URL("src/renderer/index.html", repositoryRoot),
        "utf8",
      );
      const html = await server.transformIndexHtml("/", source);

      expect(html).toContain('src="/@vite/client"');
      expect(html).toContain('from "/@react-refresh"');
      expect(html).toContain("script-src 'self' 'unsafe-eval' 'unsafe-inline'");
      expect(html).toContain("ws://localhost:5173");
    } finally {
      await server.close();
      if (previousDevMode === undefined) {
        delete process.env.SLATESYNC_RENDERER_DEV;
      } else {
        process.env.SLATESYNC_RENDERER_DEV = previousDevMode;
      }
    }
  });
});
