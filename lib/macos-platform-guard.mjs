import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MACOS_PLATFORM = "darwin";

/**
 * Keep every current Electron development, packaging, and OCR entrypoint on
 * the same native platform contract. Legacy cross-platform helpers remain in
 * the source tree for migration tests, but they are not current entrypoints.
 */
export function assertMacOSPlatform(platform = process.platform) {
  if (platform !== MACOS_PLATFORM) {
    throw new Error("[SlateSync] 当前产品仅支持在 macOS 主机上运行和打包 macOS 应用。");
  }
  return MACOS_PLATFORM;
}

const invokedDirectly = process.argv[1]
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  try {
    assertMacOSPlatform();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
