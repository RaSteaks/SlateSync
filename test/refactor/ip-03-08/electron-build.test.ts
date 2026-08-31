import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  buildHostArguments,
  resolveHostTarget,
} from "../../../scripts/electron-build-host.mjs";

const repositoryRoot = new URL("../../../", import.meta.url);

describe("host-specific Electron packaging", () => {
  it("uses guarded host entrypoints and declares macOS/Windows targets", async () => {
    const [packageJson, builderConfig, buildScript] = await Promise.all([
      readFile(new URL("package.json", repositoryRoot), "utf8").then(JSON.parse),
      readFile(new URL("electron-builder.yml", repositoryRoot), "utf8"),
      readFile(new URL("scripts/electron-build-host.mjs", repositoryRoot), "utf8"),
    ]);

    expect(packageJson.scripts["electron:build"]).toBe("node scripts/electron-build-host.mjs");
    expect(packageJson.scripts["electron:build:dir"]).toBe("node scripts/electron-build-host.mjs --dir");
    expect(packageJson.scripts.check).toContain("node --check scripts/electron-build-host.mjs");
    expect(builderConfig).toMatch(/^win:\n  target:\n    - target: nsis\n      arch: \[x64\]/m);
    expect(builderConfig).not.toMatch(/^linux:/m);
    expect(builderConfig).toMatch(/^mac:[\s\S]*?extraResources:\n    - from: bin\/\n      to: app\/bin\/\n/m);
    expect(builderConfig).not.toMatch(/^extraResources:[\s\S]*?from: bin\/\n/m);
    expect(buildScript).toContain("hostTargets");
    expect(buildScript).toContain('"--mac"');
    expect(buildScript).toContain('"--win"');
    expect(buildScript).toContain('"--x64"');

    // Keep the regression guard close to the packaging entrypoint so a future
    // convenience flag cannot reintroduce Windows ia32/x86 artifacts.
    for (const flag of ["--win", "--windows", "-w", "-o", "--ia32", "--x86"]) {
      expect(buildScript).toContain(`"${flag}"`);
    }
  });

  it("maps each supported host to one package platform and Windows x64", () => {
    expect(resolveHostTarget("darwin")).toMatchObject({ label: "macOS", builderFlag: "--mac" });
    expect(resolveHostTarget("win32")).toMatchObject({ label: "Windows", builderFlag: "--win" });
    expect(buildHostArguments("darwin")).toEqual(["--mac"]);
    expect(buildHostArguments("win32")).toEqual(["--win", "--x64"]);
    expect(buildHostArguments("win32", ["--x64", "--dir"])).toEqual(["--win", "--x64", "--dir"]);
    expect(() => resolveHostTarget("linux")).toThrow(/macOS 或 Windows/);
    expect(() => buildHostArguments("darwin", ["--win"])).toThrow(/不能生成 win32 包/);
    expect(() => buildHostArguments("darwin", ["-mw"])).toThrow(/不能生成 win32 包/);
    expect(() => buildHostArguments("win32", ["-wl"])).toThrow(/不能生成 linux 包/);
    expect(() => buildHostArguments("win32", ["--ia32"])).toThrow(/ia32\/x86/);
    expect(() => buildHostArguments("win32", ["--arm64"])).toThrow(/固定使用 x64/);
  });

  it("rejects unsupported packaging requests before electron-builder starts", async () => {
    const buildScript = fileURLToPath(new URL("scripts/electron-build-host.mjs", repositoryRoot));
    const result = spawnSync(process.execPath, [buildScript, "--linux", "--help"], {
      encoding: "utf8",
    });
    const output = `${result.stdout}${result.stderr}`;

    expect(result.status).toBe(1);
    if (process.platform === "darwin" || process.platform === "win32") {
      expect(output).toContain("不能生成 linux 包");
    } else {
      expect(output).toContain("当前只支持在 macOS 或 Windows");
    }
  });
});
