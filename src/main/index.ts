/**
 * Typed Main build boundary. Runtime composition remains in electron/main.mjs
 * until a later package migrates the production composition root.
 */
export const MAIN_BUILD_TARGET = "main" as const;

export type MainBuildTarget = typeof MAIN_BUILD_TARGET;

export { selectRendererEntry } from "./renderer-entry.js";
export type {
  RendererEntry,
  RendererEntryOptions,
  RendererMode,
} from "./renderer-entry.js";
