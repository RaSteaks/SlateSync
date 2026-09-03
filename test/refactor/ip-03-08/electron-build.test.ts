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
import { assertMacOSPlatform } from "../../../lib/macos-platform-guard.mjs";

const repositoryRoot = new URL("../../../", import.meta.url);

describe("host-specific Electron packaging", () => {
  it("uses guarded macOS entrypoints and declares no other package target", async () => {
    const [packageJson, builderConfig, buildScript] = await Promise.all([
      readFile(new URL("package.json", repositoryRoot), "utf8").then(JSON.parse),
      readFile(new URL("electron-builder.yml", repositoryRoot), "utf8"),
      readFile(new URL("scripts/electron-build-host.mjs", repositoryRoot), "utf8"),
    ]);

    expect(packageJson.scripts["electron:build"]).toBe("node scripts/electron-build-host.mjs");
    expect(packageJson.scripts["electron:build:dir"]).toBe("node scripts/electron-build-host.mjs --dir");
    expect(packageJson.scripts.check).toContain("node --check scripts/electron-build-host.mjs");
    expect(builderConfig).not.toMatch(/^win:/m);
    expect(builderConfig).not.toMatch(/^linux:/m);
    expect(builderConfig).toMatch(/^mac:[\s\S]*?minimumSystemVersion: "15\.0"/m);
    expect(builderConfig).toMatch(/^mac:[\s\S]*?extraResources:\n    - from: bin\/\n      to: app\/bin\/\n/m);
    expect(builderConfig).not.toMatch(/^extraResources:[\s\S]*?from: bin\/\n/m);
    expect(buildScript).toContain("macOSTarget");
    expect(buildScript).toContain('"--mac"');
    expect(buildScript).toContain("assertMacOSPlatform");

    // The platform contract is asserted behaviorally below; source text alone
    // cannot prove that an alias is rejected before electron-builder starts.
    expect(buildScript).toContain("rejectedPlatformFlags");
  });

  it("maps the only supported host to macOS and rejects other hosts/targets", () => {
    expect(resolveHostTarget("darwin")).toMatchObject({ label: "macOS", builderFlag: "--mac" });
    expect(buildHostArguments("darwin")).toEqual(["--mac"]);
    expect(() => resolveHostTarget("win32")).toThrow(/仅支持在 macOS/);
    expect(() => resolveHostTarget("linux")).toThrow(/仅支持在 macOS/);
    expect(() => buildHostArguments("darwin", ["--win"])).toThrow(/拒绝 win32/);
    expect(() => buildHostArguments("darwin", ["-mw"])).toThrow(/拒绝 win32/);
    expect(() => buildHostArguments("darwin", ["--linux"])).toThrow(/拒绝 linux/);
    expect(() => buildHostArguments("darwin", ["--ia32"])).toThrow(/macOS 当前打包不支持/);
    expect(() => assertMacOSPlatform("win32")).toThrow(/仅支持在 macOS/);
  });

  it("rejects unsupported packaging requests before electron-builder starts", async () => {
    const buildScript = fileURLToPath(new URL("scripts/electron-build-host.mjs", repositoryRoot));
    const result = spawnSync(process.execPath, [buildScript, "--linux", "--help"], {
      encoding: "utf8",
    });
    const output = `${result.stdout}${result.stderr}`;

    expect(result.status).toBe(1);
    expect(output).toContain("拒绝 linux");
  });

  it("selects the bridge architecture from the package target", () => {
    expect(visionBridgeArchitecture("darwin")).toBe("universal");
    expect(visionBridgeArchitecture("darwin", ["--arm64"])).toBe("arm64");
    expect(visionBridgeArchitecture("darwin", ["--x64"])).toBe("x64");
    expect(visionBridgeArchitecture("darwin", ["--arm64", "--x64"])).toBe("universal");
    expect(visionBridgeArchitecture("darwin", ["--universal"])).toBe("universal");
    expect(() => visionBridgeArchitecture("win32", ["--x64"])).toThrow(/仅支持在 macOS/);
    expect(visionArchitectureFromArgs(["--arch", "arm64"])).toBe("arm64");
    expect(visionArchitectureFromArgs(["--arch", "universal"])).toBe("universal");
    expect(visionArchitectureFromArgs(["--arch", "x86_64"])).toBe("x64");
    expect(() => visionArchitectureFromArgs(["--arch", "ia32"])).toThrow(/不支持的 Vision OCR 架构/);
  });

  it("rejects Vision compilation outside macOS", () => {
    let commandCount = 0;
    expect(() => buildVisionOcr({
      platform: "win32",
      runCommand: () => {
        commandCount += 1;
        return { status: 0, stdout: "", stderr: "" };
      },
    })).toThrow(/仅支持在 macOS/);
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

  it("rejects a non-macOS package before invoking bridge or builder", () => {
    let bridgeCalls = 0;
    let builderCalls = 0;
    expect(() => runHostPackaging({
      platform: "win32",
      args: ["--dir"],
      buildBridge: () => {
        bridgeCalls += 1;
      },
      spawn: () => {
        builderCalls += 1;
        return { status: 0 };
      },
    })).toThrow(/仅支持在 macOS/);
    expect(bridgeCalls).toBe(0);
    expect(builderCalls).toBe(0);
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
