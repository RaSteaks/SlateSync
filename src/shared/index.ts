/** Shared owns transport-neutral contracts; Electron and DOM types stay out. */
export const SHARED_BUILD_TARGET = "shared" as const;

export * from "./contracts/index.js";
export { toAppError } from "./errors/index.js";
