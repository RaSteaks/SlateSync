import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function read(relativePath) {
  return readFileSync(resolve(repositoryRoot, relativePath), "utf8");
}

function requireCondition(condition, message) {
  assert.ok(condition, `[SM-03] ${message}`);
}

function assertFilesAndComments() {
  for (const relativePath of [
    "Sources/SlateSyncDomain/DomainContracts.swift",
    "Sources/SlateSyncDomain/CustomProviderValidation.swift",
    "Sources/SlateSyncDomain/ExtendedContracts.swift",
    "Sources/SlateSyncDomain/AdditionalContracts.swift",
    "Sources/SlateSyncDomain/GlobalSettingsContracts.swift",
    "Sources/SlateSyncDomain/JSONValue.swift",
    "Sources/SlateSyncDomain/HTTPURLNormalizer.swift",
    "Sources/SlateSyncDomain/JavaScriptCompatibility.swift",
    "Sources/SlateSyncDomain/StructuredLogging.swift",
    "Sources/SlateSyncPersistence/AtomicFileWriter.swift",
    "Sources/SlateSyncPersistence/ConfigurationResolver.swift",
    "Sources/SlateSyncPersistence/GlobalConfigStore.swift",
    "Sources/SlateSyncPersistence/MachineSettingsStore.swift",
    "Sources/SlateSyncPersistence/KeychainCredentialStore.swift",
    "Sources/SlateSyncPersistence/SlateSyncRuntime.swift",
    "Sources/SlateSyncUI/Models/SlateSyncRuntimeModel.swift",
    "SlateSyncApp/App/SlateSyncApp.swift",
    "SlateSyncTests/SlateSyncTests.swift",
    "Tests/SlateSyncDomainTests/Fixtures/legacy-task.json",
    "Tests/SlateSyncDomainTests/Fixtures/legacy-project.json",
    "Tests/SlateSyncPersistenceTests/Fixtures/global-config-v2.json",
    "Tests/SlateSyncPersistenceTests/Support/InMemoryKeychainBackend.swift",
  ]) {
    requireCondition(existsSync(resolve(repositoryRoot, relativePath)), `缺少 SM-03 文件：${relativePath}`);
  }

  const sources = [
    read("Sources/SlateSyncDomain/DomainContracts.swift"),
    read("Sources/SlateSyncDomain/CustomProviderValidation.swift"),
    read("Sources/SlateSyncDomain/GlobalSettingsContracts.swift"),
    read("Sources/SlateSyncDomain/HTTPURLNormalizer.swift"),
    read("Sources/SlateSyncDomain/JavaScriptCompatibility.swift"),
    read("Sources/SlateSyncDomain/StructuredLogging.swift"),
    read("Sources/SlateSyncPersistence/ConfigurationResolver.swift"),
    read("Sources/SlateSyncPersistence/KeychainCredentialStore.swift"),
    read("Sources/SlateSyncPersistence/SlateSyncRuntime.swift"),
  ].join("\n");
  requireCondition((sources.match(/\/\/|\/\*/g) ?? []).length >= 12, "新增实现缺少与边界对应的代码注释");
}

function assertTypedBoundaries() {
  const packageSource = read("Package.swift");
  const domainSource = [
    read("Sources/SlateSyncDomain/ProjectModels.swift"),
    read("Sources/SlateSyncDomain/DomainContracts.swift"),
    read("Sources/SlateSyncDomain/ExtendedContracts.swift"),
  ].join("\n");
  const providerSource = read("Sources/SlateSyncDomain/DomainContracts.swift");
  const settingsSource = read("Sources/SlateSyncDomain/GlobalSettingsContracts.swift");
  const resolverSource = read("Sources/SlateSyncPersistence/ConfigurationResolver.swift");
  const loggingSource = read("Sources/SlateSyncDomain/StructuredLogging.swift");
  const keychainSource = read("Sources/SlateSyncPersistence/KeychainCredentialStore.swift");
  const runtimeSource = read("Sources/SlateSyncPersistence/SlateSyncRuntime.swift");
  const appSource = read("SlateSyncApp/App/SlateSyncApp.swift");
  const xcodeTestSource = read("SlateSyncTests/SlateSyncTests.swift");
  const urlSource = read("Sources/SlateSyncDomain/HTTPURLNormalizer.swift");
  const compatibilitySource = read("Sources/SlateSyncDomain/JavaScriptCompatibility.swift");

  requireCondition(packageSource.includes('resources: [.process("Fixtures")]'), "SwiftPM 测试 fixture 未注册");
  requireCondition(domainSource.includes("public struct TaskData") && domainSource.includes("public struct ProjectSettings"), "领域合同未覆盖任务与项目设置");
  requireCondition(settingsSource.includes("public enum GlobalSettingKey") && settingsSource.includes("GlobalSettingsValidator"), "全局设置没有显式 typed key/validator");
  requireCondition(
    settingsSource.includes("case explicit") &&
      settingsSource.includes("case globalSettings") &&
      settingsSource.includes("case defaults") &&
      resolverSource.includes("GlobalSettingsResolution.resolve"),
    "配置解析没有保留来源优先级",
  );
  requireCondition(
    resolverSource.includes("GlobalSettingsResolution.resolve") &&
      resolverSource.includes("legacySettings") && settingsSource.includes("legacyPaddlePythonPath"),
    "旧 settings.json 的 Paddle Python 兼容回退缺失",
  );
  requireCondition(loggingSource.includes("import OSLog") && loggingSource.includes("Logger(subsystem:"), "没有使用结构化 OSLog 入口");
  requireCondition(loggingSource.includes("StructuredLogRedactor") && loggingSource.includes("redactText"), "日志没有可测试的递归脱敏边界");
  requireCondition(keychainSource.includes("public protocol KeychainBackend") && keychainSource.includes("migrateLegacyCredentials"), "Keychain 没有可注入迁移边界");
  requireCondition(keychainSource.includes("readBack") && keychainSource.includes("compensate") && keychainSource.includes("deleteIfMatching"), "Keychain 迁移没有写后校验、条件回滚与补偿路径");
  requireCondition(keychainSource.includes("kSecUseDataProtectionKeychain") && keychainSource.includes("kSecAttrAccessibleAfterFirstUnlock"), "生产 Keychain 缺少 Data Protection/AfterFirstUnlock 属性");
  requireCondition(keychainSource.includes("query[kSecValueData as String] = expected") && keychainSource.includes("coordinationDirectory"), "Keychain 条件删除或稳定锁命名空间缺失");
  requireCondition(!existsSync(resolve(repositoryRoot, "Sources/SlateSyncPersistence/InMemoryKeychainBackend.swift")), "InMemory Keychain 后端不能进入生产 target");
  requireCondition(!domainSource.includes("[String: Any]") && !settingsSource.includes("[String: Any]"), "已知领域合同退回非类型化 Any 容器");
  requireCondition(providerSource.includes("public enum DomainResult"), "缺少 TS Result<T> 的 typed envelope");
  const persistedProvider = providerSource.match(/public struct CustomProviderConfiguration[\s\S]*?\n}\n/);
  requireCondition(persistedProvider && !persistedProvider[0].includes("apiKey"), "持久化 provider 合同不应携带 API key 字段");
  requireCondition(!/safeEvent\.message, privacy: \.public/.test(loggingSource), "日志 message 不得依赖正则脱敏后以 public privacy 写入");
  requireCondition(compatibilitySource.includes("utf16Length") && compatibilitySource.includes("numberString"), "JavaScript 数字/UTF-16 兼容层缺失");
  requireCondition(urlSource.includes("!host.contains(\"%\")"), "URL normalizer 未拒绝 IPv6 zone-id");
  requireCondition(loggingSource.includes("maximumDepth") && loggingSource.includes("AIza"), "日志递归深度或 Google 凭据形态缺失");
  requireCondition(keychainSource.includes("private static let maximumDepth"), "旧凭据 JSON 扫描器缺少递归深度上限");
  requireCondition(runtimeSource.includes("public actor SlateSyncRuntime") && runtimeSource.includes("retryLegacyMigration"), "原生 runtime bootstrap/重试入口缺失");
  requireCondition(appSource.includes("SlateSyncRuntime(locator: locator)") && appSource.includes("runtimeModel.bootstrap"), "App 启动没有接入 runtime bootstrap");
  requireCondition(xcodeTestSource.includes("SecurityKeychainBackend") && xcodeTestSource.includes("deleteIfMatching"), "缺少真实 SecurityKeychainBackend Xcode 测试");
}

function assertGlobalSettingKeysMatchSharedContract() {
  const typescript = read("src/shared/contracts/index.ts");
  const swift = read("Sources/SlateSyncDomain/GlobalSettingsContracts.swift");
  const expected = [...typescript.matchAll(/^\s*\|\s*"([A-Z0-9_]+)"/gm)].map((match) => match[1]);
  const actual = [...swift.matchAll(/^\s*case\s+\w+\s*=\s*"([A-Z0-9_]+)"/gm)].map((match) => match[1]);
  requireCondition(expected.length > 0 && new Set(expected).size === expected.length, "TS 全局设置 key 合同解析失败");
  assert.deepEqual(actual, expected, "Swift GlobalSettingKey 与 TS shared contract 不一致");
}

function assertSM03AdmissionState(currentState) {
  requireCondition(currentState.lifecycleState === "COMPLETE", "SM-03 admission 必须来自 COMPLETE 状态");
  const phaseNumber = Number(String(currentState.phase || "").replace(/^SM-/, ""));
  requireCondition([2, 3].includes(phaseNumber), "SM-03 只接受 SM-02 或 SM-03 的合法阶段状态");
  requireCondition(
    currentState.activePackage === `.codex/swift-migration/packages/SM-${String(phaseNumber).padStart(2, "0")}.md`,
    "当前状态 activePackage 与阶段不一致",
  );
  const expectedNext = `.codex/swift-migration/packages/SM-${String(phaseNumber + 1).padStart(2, "0")}.md`;
  requireCondition(currentState.nextPackage === expectedNext, "当前状态 nextPackage 与阶段不一致");
  if (phaseNumber === 2) {
    requireCondition(currentState.nextPackage === ".codex/swift-migration/packages/SM-03.md", "SM-02 pre-admission 未指向 SM-03");
  }
  if (phaseNumber === 3) {
    requireCondition(currentState.nextPackage === ".codex/swift-migration/packages/SM-04.md", "SM-03 post-admission 未指向 SM-04");
  }
}

function assertCompatibilityAndState() {
  const currentState = JSON.parse(read(".codex/swift-migration/CURRENT_STATE.json"));
  assertSM03AdmissionState(currentState);
  // Exercise the post-admission shape without changing the repository's
  // governance state; a rerun after Owner approval must remain valid too.
  assertSM03AdmissionState({
    phase: "SM-03",
    lifecycleState: "COMPLETE",
    activePackage: ".codex/swift-migration/packages/SM-03.md",
    nextPackage: ".codex/swift-migration/packages/SM-04.md",
  });
  assert.throws(
    () => assertSM03AdmissionState({
      phase: "SM-03",
      lifecycleState: "IN_PROGRESS",
      activePackage: ".codex/swift-migration/packages/SM-03.md",
      nextPackage: ".codex/swift-migration/packages/SM-04.md",
    }),
    /COMPLETE/,
  );
  for (const relativePath of [
    ".codex/refactor/README.md",
    "electron/main.mjs",
    "src/shared/contracts/index.ts",
    "package.json",
  ]) {
    requireCondition(existsSync(resolve(repositoryRoot, relativePath)), `兼容基线缺失：${relativePath}`);
  }
  requireCondition(!existsSync(resolve(repositoryRoot, "Sources/SlateSyncPersistence/SQLiteMigration.swift")), "SM-04 SQLite 迁移越过当前范围");
}

assertFilesAndComments();
assertTypedBoundaries();
assertGlobalSettingKeysMatchSharedContract();
assertCompatibilityAndState();
console.log("SM-03 contract: typed domain DTOs, settings precedence, OSLog redaction, transactional Keychain seam, fixtures, and compatibility boundary verified");
