/**
 * Renderer selection is a pure composition decision. Modern is the only
 * normal development/packaged entry; legacy remains a bounded recovery path
 * for an explicit internal switch or missing/corrupt modern assets.
 */
export type RendererMode = "legacy" | "modern";

export interface RendererEntry {
  mode: RendererMode;
  root: string;
  htmlPath: string;
  reason: "legacy-explicit" | "modern-default" | "modern-requested" | "modern-missing";
}

export interface RendererEntryOptions {
  isDevelopment: boolean;
  requestedModern: boolean;
  modernAvailable: boolean;
  legacyRoot: string;
  modernRoot: string;
}

export function selectRendererEntry(options: RendererEntryOptions): RendererEntry {
  if (!options.requestedModern) {
    return {
      mode: "legacy",
      root: options.legacyRoot,
      htmlPath: `${options.legacyRoot}/index.html`,
      reason: "legacy-explicit",
    };
  }

  if (!options.modernAvailable) {
    return {
      mode: "legacy",
      root: options.legacyRoot,
      htmlPath: `${options.legacyRoot}/index.html`,
      reason: "modern-missing",
    };
  }

  return {
    mode: "modern",
    root: options.modernRoot,
    htmlPath: `${options.modernRoot}/index.html`,
    reason: options.isDevelopment ? "modern-requested" : "modern-default",
  };
}
