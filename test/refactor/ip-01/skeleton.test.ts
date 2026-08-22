import { describe, expect, it } from "vitest";
import { MAIN_BUILD_TARGET, selectRendererEntry } from "../../../src/main/index";
import { PRELOAD_BUILD_TARGET } from "../../../src/preload/index";
import { SHARED_BUILD_TARGET } from "../../../src/shared/index";

describe("IP-01 build skeleton", () => {
  it("keeps the four target ownership markers separate", () => {
    expect(MAIN_BUILD_TARGET).toBe("main");
    expect(PRELOAD_BUILD_TARGET).toBe("preload");
    expect(SHARED_BUILD_TARGET).toBe("shared");
  });

  it("defaults to modern, preserves explicit legacy recovery, and rejects missing modern assets", () => {
    expect(selectRendererEntry({
      isDevelopment: true,
      requestedModern: true,
      modernAvailable: true,
      legacyRoot: "/app/public",
      modernRoot: "/app/out/renderer",
    })).toMatchObject({ mode: "modern", reason: "modern-requested", htmlPath: "/app/out/renderer/index.html" });

    expect(selectRendererEntry({
      isDevelopment: true,
      requestedModern: false,
      modernAvailable: true,
      legacyRoot: "/app/public",
      modernRoot: "/app/out/renderer",
    })).toMatchObject({ mode: "legacy", reason: "legacy-explicit", htmlPath: "/app/public/index.html" });

    expect(selectRendererEntry({
      isDevelopment: false,
      requestedModern: true,
      modernAvailable: true,
      legacyRoot: "/app/public",
      modernRoot: "/app/out/renderer",
    })).toMatchObject({ mode: "modern", reason: "modern-default", htmlPath: "/app/out/renderer/index.html" });

    expect(selectRendererEntry({
      isDevelopment: true,
      requestedModern: true,
      modernAvailable: false,
      legacyRoot: "/app/public",
      modernRoot: "/app/out/renderer",
    })).toMatchObject({ mode: "legacy", reason: "modern-missing" });
  });
});
