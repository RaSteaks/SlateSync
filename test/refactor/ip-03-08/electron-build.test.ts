import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  buildHostArguments,
  resolveHostTarget,
  runHostPackaging,
  visionBridgeArchitecture,
} from "../../../scripts/electron-build-host.mjs";
import {
  buildVisionOcr,
  verifyVisionOcrBinary,
  visionArchitectureFromArgs,
} from "../../../scripts/build-vision-ocr.mjs";

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

  it("selects the bridge architecture from the package target", () => {
    expect(visionBridgeArchitecture("darwin")).toBe("universal");
    expect(visionBridgeArchitecture("darwin", ["--arm64"])).toBe("arm64");
    expect(visionBridgeArchitecture("darwin", ["--x64"])).toBe("x64");
    expect(visionBridgeArchitecture("darwin", ["--arm64", "--x64"])).toBe("universal");
    expect(visionBridgeArchitecture("darwin", ["--universal"])).toBe("universal");
    expect(visionBridgeArchitecture("win32", ["--x64"])).toBeNull();
    expect(visionArchitectureFromArgs(["--arch", "arm64"])).toBe("arm64");
    expect(visionArchitectureFromArgs(["--arch", "universal"])).toBe("universal");
    expect(visionArchitectureFromArgs(["--arch", "x86_64"])).toBe("x64");
    expect(() => visionArchitectureFromArgs(["--arch", "ia32"])).toThrow(/不支持的 Vision OCR 架构/);
  });

  it("skips Swift compilation on Windows", () => {
    let commandCount = 0;
    const result = buildVisionOcr({
      platform: "win32",
      runCommand: () => {
        commandCount += 1;
        return { status: 0, stdout: "", stderr: "" };
      },
    });
    expect(result).toMatchObject({ skipped: true, architecture: null });
    expect(commandCount).toBe(0);
  });

  it("builds and verifies a universal bridge through one injected command runner", () => {
    const root = mkdtempSync(join(tmpdir(), "slatesync-vision-build-test-"));
    const outputPath = join(root, "bin", "vision-ocr");
    const commands: string[] = [];
    const runCommand = (command: string, args: string[]) => {
      commands.push([command, ...args].join(" "));
      if (command === "xcrun") {
        const output = args[args.indexOf("-o") + 1];
        writeFileSync(output, "thin bridge");
        chmodSync(output, 0o755);
      } else if (command === "lipo" && args[0] === "-create") {
        const output = args[args.indexOf("-output") + 1];
        writeFileSync(output, "universal bridge");
        chmodSync(output, 0o755);
      } else if (command === "lipo" && args[0] === "-archs") {
        return { status: 0, stdout: "arm64 x86_64\n", stderr: "" };
      } else if (command === outputPath) {
        return {
          status: 0,
          stdout: '__SLATESYNC_OCR_JSON__{"ok":true,"engine":"Vision"}\n',
          stderr: "",
        };
      }
      return { status: 0, stdout: "", stderr: "" };
    };

    try {
      const result = buildVisionOcr({
        platform: "darwin",
        architecture: "universal",
        outputPath,
        runCommand,
      });
      expect(result).toMatchObject({
        skipped: false,
        architecture: "universal",
        actualArchitectures: ["arm64", "x86_64"],
      });
      expect(existsSync(outputPath)).toBe(true);
      expect(commands.filter((command) => command.startsWith("xcrun "))).toHaveLength(2);
      expect(commands.some((command) => command.startsWith("lipo -create"))).toBe(true);
      expect(commands.at(-1)).toBe([outputPath, "--check"].join(" "));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("does not invoke the bridge builder for a Windows host package", () => {
    let bridgeCalls = 0;
    let builderCalls = 0;
    const status = runHostPackaging({
      platform: "win32",
      args: ["--dir"],
      buildBridge: () => {
        bridgeCalls += 1;
      },
      spawn: () => {
        builderCalls += 1;
        return { status: 0 };
      },
    });
    expect(status).toBe(0);
    expect(bridgeCalls).toBe(0);
    expect(builderCalls).toBe(1);
  });

  it("reports a precise architecture verification failure", () => {
    const root = mkdtempSync(join(tmpdir(), "slatesync-vision-verify-test-"));
    const binaryPath = join(root, "vision-ocr");
    writeFileSync(binaryPath, "thin bridge");
    chmodSync(binaryPath, 0o755);
    try {
      expect(() => verifyVisionOcrBinary({
        binaryPath,
        architecture: "universal",
        runCommand: (_command: string, args: string[]) => {
          if (args[0] === "-archs") {
            return { status: 0, stdout: "arm64\n", stderr: "" };
          }
          return { status: 0, stdout: "", stderr: "" };
        },
      })).toThrow(/Vision OCR 架构不匹配：期望 arm64\+x86_64/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
