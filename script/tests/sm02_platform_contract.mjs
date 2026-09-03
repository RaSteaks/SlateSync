import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildHostArguments,
  resolveHostTarget,
  runHostPackaging,
  visionBridgeArchitecture,
} from "../../scripts/electron-build-host.mjs";
import { buildVisionOcr } from "../../scripts/build-vision-ocr.mjs";
import { assertMacOSPlatform } from "../../lib/macos-platform-guard.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function read(relativePath) {
  return readFileSync(resolve(repositoryRoot, relativePath), "utf8");
}

function requireCondition(condition, message) {
  assert.ok(condition, `[SM-02] ${message}`);
}

function topLevelYamlKeys(source) {
  return source
    .split(/\r?\n/)
    .map((line) => line.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*$/)?.[1])
    .filter(Boolean);
}

function macBuilderBlock(source) {
  const match = source.match(/^mac:\n([\s\S]*?)(?=^[A-Za-z][A-Za-z0-9_-]*:\s*$)/m);
  requireCondition(match, "electron-builder.yml 缺少 mac 配置块");
  return match[1];
}

function assertCurrentPackageEntrypoints() {
  const packageJson = JSON.parse(read("package.json"));
  const scripts = packageJson.scripts;
  const nativeRunScript = read("script/build_and_run.sh");
  const electronMain = read("electron/main.mjs");
  const forbiddenNames = /(?:win|windows|linux|appimage|nsis|deb|rpm)/i;
  const forbiddenBuilderFlags = /(?:--win(?:=|\b)|--linux(?:=|\b)|nsis|appimage|\bdeb\b|\brpm\b)/i;

  requireCondition(scripts["electron:build"] === "node scripts/electron-build-host.mjs", "electron:build 未使用受保护的 macOS 包装入口");
  requireCondition(scripts["electron:build:dir"] === "node scripts/electron-build-host.mjs --dir", "electron:build:dir 未使用受保护的 macOS 包装入口");
  for (const [name, command] of Object.entries(scripts)) {
    requireCondition(!forbiddenNames.test(name), `当前 npm script 名称声明了废弃平台：${name}`);
    requireCondition(!forbiddenBuilderFlags.test(command), `当前 npm script 包含废弃平台打包目标：${name}`);
  }
  for (const name of ["start", "dev", "electron:dev", "electron:dev:modern", "electron:build", "electron:build:dir", "ocr:setup", "ocr:check"]) {
    const lifecycleGuarded = name.startsWith("electron:build")
      ? scripts[`pre${name}`]?.includes("macos-platform-guard")
      : false;
    requireCondition(
      scripts[name]?.includes("macos-platform-guard") || lifecycleGuarded || name === "start" || name === "dev",
      `当前入口 ${name} 未经过 macOS 平台前置检查`,
    );
  }
  for (const name of ["release:mac", "release:mac:publish"]) {
    requireCondition(scripts[name]?.includes("electron-builder --mac"), `${name} 未固定 macOS electron-builder 目标`);
    requireCondition(!forbiddenBuilderFlags.test(scripts[name]), `${name} 仍包含废弃平台目标`);
  }
  requireCondition(nativeRunScript.includes('$(uname -s)" != "Darwin"'), "原生 macOS 运行入口缺少平台前置检查");
  requireCondition(nativeRunScript.includes("-destination 'platform=macOS'"), "原生运行入口未固定 macOS destination");
  requireCondition(nativeRunScript.includes('/usr/bin/open -g -n "$app_path"'), "自动验证入口未保持后台启动");
  requireCondition(electronMain.includes("assertMacOSPlatform();"), "直接 Electron Main 入口缺少 macOS 平台前置检查");
}

function assertBuilderConfiguration() {
  const source = read("electron-builder.yml");
  const keys = topLevelYamlKeys(source);
  requireCondition(keys.includes("mac"), "electron-builder.yml 未声明 macOS 目标");
  requireCondition(!keys.includes("win") && !keys.includes("linux"), "electron-builder.yml 仍声明 Windows/Linux 顶层目标");
  requireCondition(!/^\s+- target:\s*(?:nsis|appimage|deb|rpm|snap|flatpak)\s*$/im.test(source), "electron-builder.yml 仍包含非 macOS 安装器");

  const mac = macBuilderBlock(source);
  const targets = [...mac.matchAll(/^\s+- target:\s*(\S+)\s*\n\s+arch:\s*\[([^\]]+)\]/gm)]
    .map(([, target, architectures]) => `${target}:${architectures.split(",").map((value) => value.trim()).join(",")}`);
  assert.deepEqual(
    targets.sort(),
    ["dmg:arm64,x64", "zip:arm64,x64"],
    "macOS DMG/ZIP 必须继续覆盖 arm64 与 x86_64",
  );
  requireCondition(mac.includes('minimumSystemVersion: "15.0"'), "Electron macOS 包未固定最低系统 15.0");
  requireCondition(mac.includes("entitlements: build/entitlements.mac.plist"), "macOS 打包未保留既有 entitlements");
  requireCondition(mac.includes("from: bin/\n      to: app/bin/"), "macOS 包未包含 Vision OCR 资源路径");
}

function assertMacOSWorkflows() {
  const ci = read(".github/workflows/ci.yml");
  const release = read(".github/workflows/release.yml");
  for (const [name, source] of [["CI", ci], ["release", release]]) {
    const runners = [...source.matchAll(/^\s+runs-on:\s*([^\n]+)$/gm)].map(([, runner]) => runner.trim());
    requireCondition(runners.length > 0 && runners.every((runner) => runner === "macos-14"), `${name} 存在非 macOS runner`);
    requireCondition(!/(?:ubuntu|windows|linux|appimage|nsis)/i.test(source), `${name} 仍包含非 macOS 平台声明或产物目标`);
    requireCondition(source.includes("./script/phase_gate.sh SM-02"), `${name} 未调用共享 SM-02 phase Gate`);
    requireCondition(!source.includes("--allow-dirty"), `${name} 不得用 dirty diagnostic 替代正式 Gate`);
  }
  requireCondition(release.includes("dist/*.dmg") && release.includes("dist/*.zip"), "release 未验证 macOS DMG/ZIP 产物");
  requireCondition(!/dist\/[^\s]*\.(?:exe|msi|AppImage|deb|rpm)/i.test(release), "release 仍上传非 macOS 产物");
}

function assertNativeReleaseContract() {
  const packageSource = read("Package.swift");
  const projectSource = read("SlateSync.xcodeproj/project.pbxproj");
  const schemeSource = read("SlateSync.xcodeproj/xcshareddata/xcschemes/SlateSync.xcscheme");
  const phaseGateSource = read("script/phase_gate.sh");
  requireCondition(packageSource.includes("platforms: [.macOS(.v15)]"), "SwiftPM 最低系统已偏离 macOS 15");
  requireCondition(projectSource.includes("MACOSX_DEPLOYMENT_TARGET = 15.0;"), "Xcode 工程未保留 macOS 15 deployment target");
  requireCondition(projectSource.includes("ONLY_ACTIVE_ARCH = NO;"), "Release 未保留 Universal 构建设置");
  requireCondition(projectSource.includes('CODE_SIGN_IDENTITY = "-";'), "ad-hoc 本地签名契约已丢失");
  requireCondition(schemeSource.includes('<ArchiveAction buildConfiguration="Release"'), "共享 Scheme 未保留 Release Archive");
  requireCondition(
    phaseGateSource.includes('[[ "$phase" == "SM-01" || "$phase" == "SM-02" ]]'),
    "SM-02 Gate 未继续执行 SM-01 建立的产物级验证",
  );
  for (const check of ["sm01_real_app_launch", "sm01_release_artifact", "sm01_archive_artifact"]) {
    requireCondition(phaseGateSource.includes(`run_check ${check}`), `SM-02 Gate 缺少 ${check} 运行验证`);
  }
  requireCondition(
    phaseGateSource.includes("./script/build_and_run.sh --debug --verify --background"),
    "SM-02 Gate 的真实 App 验证未使用后台启动模式",
  );
}

function assertPlatformGuards() {
  assert.equal(assertMacOSPlatform("darwin"), "darwin");
  assert.throws(() => assertMacOSPlatform("win32"), /仅支持在 macOS/);
  assert.throws(() => assertMacOSPlatform("linux"), /仅支持在 macOS/);

  assert.deepEqual(resolveHostTarget("darwin"), { label: "macOS", builderFlag: "--mac" });
  for (const platform of ["win32", "linux"]) {
    assert.throws(() => resolveHostTarget(platform), /仅支持在 macOS/);
    assert.throws(() => buildHostArguments(platform), /仅支持在 macOS/);
    assert.throws(() => visionBridgeArchitecture(platform), /仅支持在 macOS/);
  }
  assert.deepEqual(buildHostArguments("darwin"), ["--mac"]);
  for (const argument of ["--win", "--windows", "-w", "--linux", "-l", "-mw", "--ia32", "--x86"]) {
    assert.throws(() => buildHostArguments("darwin", [argument]), /拒绝|不支持/);
  }
  assert.equal(visionBridgeArchitecture("darwin"), "universal");
  assert.equal(visionBridgeArchitecture("darwin", ["--arm64"]), "arm64");
  assert.equal(visionBridgeArchitecture("darwin", ["--x64"]), "x64");
  assert.throws(() => buildVisionOcr({ platform: "win32" }), /仅支持在 macOS/);

  let bridgeCalls = 0;
  let builderCalls = 0;
  const status = runHostPackaging({
    platform: "darwin",
    args: ["--dir"],
    buildBridge: ({ platform, architecture }) => {
      bridgeCalls += 1;
      assert.equal(platform, "darwin");
      assert.equal(architecture, "universal");
    },
    spawn: (_command, argumentsList) => {
      builderCalls += 1;
      assert.equal(argumentsList.at(-1), "--dir");
      assert.equal(argumentsList.at(-2), "--mac");
      return { status: 0 };
    },
    resolveBuilderCli: () => "/tmp/electron-builder-cli.js",
  });
  assert.equal(status, 0);
  assert.equal(bridgeCalls, 1);
  assert.equal(builderCalls, 1);
}

function assertHistoricalBaseline() {
  for (const relativePath of [
    ".codex/refactor/README.md",
    "electron/main.mjs",
    "src/renderer/App.tsx",
    "public/app.js",
    "lib/project-library.mjs",
    "package.json",
  ]) {
    requireCondition(existsSync(resolve(repositoryRoot, relativePath)), `历史兼容基线缺失：${relativePath}`);
  }
  const protectedChanges = spawnSync(
    "git",
    ["status", "--porcelain=v1", "--untracked-files=all", "--", ".codex/refactor"],
    { cwd: repositoryRoot, encoding: "utf8" },
  );
  requireCondition(protectedChanges.status === 0, "无法检查 .codex/refactor 保护路径");
  requireCondition(!protectedChanges.stdout.trim(), ".codex/refactor 在当前工作树中被修改");
}

assertCurrentPackageEntrypoints();
assertBuilderConfiguration();
assertMacOSWorkflows();
assertNativeReleaseContract();
assertPlatformGuards();
assertHistoricalBaseline();
console.log("SM-02 platform contract: current entrypoints, macOS builder/workflows, guards, and legacy baseline verified");
