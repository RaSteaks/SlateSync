// Universal macOS extension is copied with the existing app/bin resources.
import { mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
if (process.platform === "darwin") {
  mkdirSync(`${root}/bin`, { recursive: true });
  const result = spawnSync("xcrun", ["clang", "-I", "node_modules/better-sqlite3/deps/sqlite3", "-O2", "-mmacosx-version-min=13.0", "-Wall", "-Werror", "-dynamiclib",
    "-arch", "arm64", "-arch", "x86_64", "-framework", "Security", "-framework", "CoreFoundation",
    "scripts/native/local-encryption.c", "-o", "bin/local-encryption.dylib"], { cwd: root, stdio: "inherit" });
  if (result.error || result.status !== 0) throw new Error("macOS 项目加密桥接编译失败");
}
