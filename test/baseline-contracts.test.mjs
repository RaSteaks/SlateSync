import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { electronSettings } from "../electron/env-loader.mjs";
import { PROVIDERS } from "../lib/config.mjs";
import { PROJECT_FORMAT_VERSION, LIBRARY_FORMAT_VERSION } from "../lib/project-library.mjs";
import { SQLITE_FILENAMES, openSlateDatabase, closeSlateDatabase } from "../lib/sqlite-store.mjs";
import { createTask } from "../lib/task-store.mjs";

// Inventories are reviewed expected values. Tests structurally observe the
// live source/config/database and never regenerate an inventory on drift.
const contractRoot = new URL("../.codex/refactor/baseline/contracts/", import.meta.url);
const additiveContractRoot = new URL("../.codex/refactor/additive/contracts/", import.meta.url);
const repo = new URL("../", import.meta.url);

// This independent literal keeps post-baseline features from being rewritten
// into the fixture that represents c7dafa4's historical IPC surface.
const historicalIpcMethodNames = [
  "getConfig", "saveProviderKey", "getModels", "recognize", "saveFile", "selectDirectory", "scanSlateDirectory",
  "listProjects", "getLibraryInfo", "importProjectLibrary", "exportProjectLibrary", "changeLibraryLocation",
  "createProject", "loadProject", "updateProject", "archiveProject", "restoreProject", "listTasks", "loadTask",
  "saveTask", "deleteTask", "listScenarios", "loadScenario", "importScenario", "getOcrSettings", "saveOcrSettings",
  "checkOcr",
];

async function readJson(name, base = contractRoot) {
  return JSON.parse(await readFile(new URL(name, base), "utf8"));
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function assertYamlScalar(source, key, expected) {
  assert.match(source, new RegExp(`^${escapeRegex(key)}:\\s*${escapeRegex(expected)}\\s*$`, "m"));
}

function assertYamlList(source, heading, expected) {
  const match = source.match(new RegExp(`^${escapeRegex(heading)}:\\n((?:  - [^\\n]+\\n?)+)`, "m"));
  assert.ok(match, `missing YAML list: ${heading}`);
  assert.deepEqual(match[1].trim().split("\n").map((line) => line.replace(/^\s*-\s*/, "")), expected);
}

function actualIndexes(db, tables) {
  const indexes = [];
  for (const table of tables) {
    for (const index of db.pragma(`index_list(\"${table}\")`)) {
      const columns = db.pragma(`index_xinfo(\"${index.name}\")`)
        .filter((column) => column.key)
        .map((column) => `${column.name}${column.desc ? " DESC" : ""}`);
      indexes.push({ name: index.name, table, unique: Boolean(index.unique), columns });
    }
  }
  return indexes.sort((left, right) => left.name.localeCompare(right.name));
}

function actualForeignKeys(db, tables) {
  return tables.flatMap((ownerTable) =>
    db.pragma(`foreign_key_list(\"${ownerTable}\")`).map((key) => ({
      table: ownerTable,
      from: key.from,
      to: `${key.table}.${key.to}`,
      onUpdate: key.on_update,
      onDelete: key.on_delete,
    })),
  );
}

test("historical IPC inventory remains separate from post-baseline methods", async () => {
  const [ipc, additions] = await Promise.all([
    readJson("ipc.json"),
    readJson("ipc.json", additiveContractRoot),
  ]);

  assert.equal(ipc.baselineCommit, "c7dafa4d972e5eb7be61f00e2b546d6826e70c87");
  assert.equal(additions.extendsBaselineCommit, ipc.baselineCommit);
  assert.deepEqual(Object.keys(ipc.requestMethods).sort(), [...historicalIpcMethodNames].sort());
  assert.equal(ipc.cancelRecognitionChannel, null);
  // These are post-baseline additions: capability probes, local logging and
  // machine-level settings belong to their feature packages rather than the
  // historical inventory.
  assert.deepEqual(Object.keys(additions.requestMethods).sort(), [
    "cancelRecognition",
    "checkCompatibleJsonSchema",
    "checkVisionOcr",
    "deleteProject",
    "getGlobalSettings",
    "readLogs",
    "renameLibrary",
    "saveGlobalSettings",
  ]);
  assert.deepEqual(
    Object.values(additions.requestMethods).map((contract) => contract.channel).sort(),
    [
      "cancel-recognition",
      "check-compatible-json-schema",
      "check-vision-ocr",
      "delete-project",
      "get-global-settings",
      "logs-read",
      "rename-library",
      "save-global-settings",
    ],
  );
});

test("baseline and additive IPC contracts expose the exact reviewed Main surface", async () => {
  const [ipc, additions] = await Promise.all([
    readJson("ipc.json"),
    readJson("ipc.json", additiveContractRoot),
  ]);
  const preload = await readFile(new URL("electron/preload.cjs", repo), "utf8");
  const typedPreload = await readFile(new URL("src/preload/index.ts", repo), "utf8");
  const sharedContracts = await readFile(new URL("src/shared/contracts/index.ts", repo), "utf8");
  const mainHandlers = await readFile(new URL("electron/ipc-handlers.mjs", repo), "utf8");
  const handlerChannels = [...mainHandlers.matchAll(/ipcMain\.handle\(\s*"([^"]+)"/g)].map((match) => match[1]);
  // Current channels are verified as a union, while the historical fixture is
  // locked above instead of absorbing feature-package additions.
  const contracts = [ipc, additions];
  const expectedChannels = contracts.flatMap((contract) => Object.values(contract.requestMethods).map((method) => method.channel));

  assert.match(preload, /Transition marker only/);
  assert.doesNotMatch(preload, /\brequire\s*\(/);
  assert.match(typedPreload, /exposeInMainWorld/);
  assert.match(typedPreload, /process\.versions\.electron/);
  assert.match(preload + typedPreload, /slateSync/);
  assert.doesNotMatch(preload, /electronAPI/);
  assert.equal(new Set(expectedChannels).size, expectedChannels.length, "IPC contracts must not reuse request channels");
  assert.deepEqual([...new Set(handlerChannels)].sort(), [...expectedChannels].sort());
  assert.ok(typedPreload.includes(`on("${ipc.events.recognitionProgress.channel}",`));
  assert.ok(typedPreload.includes(`removeListener("${ipc.events.recognitionProgress.channel}",`));

  for (const source of contracts) {
    for (const [method, contract] of Object.entries(source.requestMethods)) {
      const requestPattern = new RegExp(`request(?:<[^>]+>)?\\("${escapeRegex(contract.channel)}"`);
      assert.match(typedPreload, requestPattern, `${method} transport drift`);
      for (const argument of contract.args) {
        if (String(argument).includes("|") || argument === "requestBody") continue;
        assert.match(typedPreload + sharedContracts, new RegExp(`\\b${escapeRegex(argument)}\\b`), `${method} missing ${argument}`);
      }
    }
  }
  assert.deepEqual(ipc.transition.namespaces, ["app", "projects", "tasks", "recognition", "files", "settings"]);
  assert.equal(ipc.transition.activeGlobal, "slateSync");
});

test("baseline package and electron-builder inventories match live configuration", async () => {
  const build = await readJson("build.json");
  const packageJson = await readJson("package.json", repo);
  const lockfile = await readJson("package-lock.json", repo);
  const builder = await readFile(new URL("electron-builder.yml", repo), "utf8");
  const ci = await readFile(new URL(".github/workflows/ci.yml", repo), "utf8");
  const release = await readFile(new URL(".github/workflows/release.yml", repo), "utf8");

  for (const key of ["name", "version", "private", "type", "main", "engines"]) {
    assert.deepEqual(packageJson[key], build.package[key], `package.${key} drift`);
  }
  const transitionScriptNames = new Set(Object.keys(build.transition.scripts));
  for (const [name, command] of Object.entries(build.package.scripts)) {
    if (transitionScriptNames.has(name)) continue;
    assert.equal(packageJson.scripts[name], command, `legacy package.scripts.${name} drift`);
  }
  for (const [name, command] of Object.entries(build.transition.scripts)) {
    assert.equal(packageJson.scripts[name], command, `IP-01 package.scripts.${name} drift`);
  }
  for (const [name, version] of Object.entries(build.package.dependencies)) {
    assert.equal(packageJson.dependencies[name], version, `legacy dependency ${name} drift`);
  }
  for (const [name, version] of Object.entries(build.transition.dependencies)) {
    assert.equal(packageJson.dependencies[name], version, `IP-01 dependency ${name} drift`);
  }
  for (const [name, version] of Object.entries(build.package.devDependencies)) {
    assert.equal(packageJson.devDependencies[name], version, `legacy devDependency ${name} drift`);
  }
  for (const [name, version] of Object.entries(build.transition.devDependencies)) {
    assert.equal(packageJson.devDependencies[name], version, `IP-01 devDependency ${name} drift`);
  }
  assert.deepEqual(lockfile.packages[""].dependencies, packageJson.dependencies);
  assert.deepEqual(lockfile.packages[""].devDependencies, packageJson.devDependencies);

  assertYamlScalar(builder, "appId", build.builder.appId);
  assertYamlScalar(builder, "productName", build.builder.productName);
  assert.match(builder, new RegExp(`^  output:\\s*${escapeRegex(build.builder.directories.output)}$`, "m"));
  assert.match(builder, new RegExp(`^  buildResources:\\s*${escapeRegex(build.builder.directories.buildResources)}$`, "m"));
  assertYamlList(builder, "files", [...build.builder.files, ...build.transition.builderFiles]);
  assertYamlList(builder, "asarUnpack", build.builder.asarUnpack);
  for (const resource of build.builder.extraResources) {
    assert.match(builder, new RegExp(`- from:\\s*${escapeRegex(resource.from)}[\\s\\S]*?to:\\s*${escapeRegex(resource.to)}`));
  }
  for (const target of build.builder.macTargets) {
    const [name, arch] = target.split(":");
    assert.match(builder, new RegExp(`- target:\\s*${escapeRegex(name)}[\\s\\S]*?arch:\\s*\\[[^\\]]*${escapeRegex(arch)}[^\\]]*\\]`));
  }
  assert.match(builder, new RegExp(`^  icon:\\s*${escapeRegex(build.builder.icon)}$`, "m"));
  assert.match(builder, new RegExp(`^  entitlements:\\s*${escapeRegex(build.builder.entitlements)}$`, "m"));
  assert.match(ci, new RegExp(`node-version:\\s*${build.ci.node}`));
  for (const command of build.ci.validation) assert.match(ci, new RegExp(escapeRegex(command)));
  for (const command of build.transition.ciValidation) assert.match(ci, new RegExp(escapeRegex(command)));
  for (const command of ["npm run check", "npm test", "electron-builder --mac"]) assert.match(release, new RegExp(escapeRegex(command)));
  for (const command of build.transition.releaseValidation) assert.match(release, new RegExp(escapeRegex(command)));
  assert.deepEqual(Object.keys(build.generatedInputs).sort(), ["bin/vision-ocr", "public/vendor/pdfjs/pdf.mjs", "public/vendor/pdfjs/pdf.worker.mjs"].sort());
});

test("baseline Electron window, navigation, renderer, and provider facts match live source", async () => {
  const [electron, providers] = await Promise.all([readJson("electron.json"), readJson("providers.json")]);
  const [main, packageJson, appSource] = await Promise.all([
    readFile(new URL("electron/main.mjs", repo), "utf8"),
    readJson("package.json", repo),
    readFile(new URL("public/app.js", repo), "utf8"),
  ]);
  assert.equal(packageJson.main, electron.entrypoint);
  for (const [key, expected] of Object.entries(electron.window)) {
    if (["externalNavigation", "externalWindow", "allowedDevNavigationRoot"].includes(key)) continue;
    const literal = typeof expected === "string" ? `\"${escapeRegex(expected)}\"` : escapeRegex(expected);
    assert.match(main, new RegExp(`\\b${escapeRegex(key)}:\\s*${literal}`), `window.${key} drift`);
  }
  assert.match(main, /preload:\s*join\(__dirname, "\.\.", "out", "preload", "index\.cjs"\)/);
  assert.match(main, /mainWindow\.loadFile\(rendererEntry\.htmlPath\)/);
  assert.match(main, /mainWindow\.loadFile\(join\(legacyRoot, "index\.html"\)\)/);
  assert.match(main, /--slatesync-renderer=modern/);
  assert.match(main, /setWindowOpenHandler\(\(\) => \(\{ action: "deny" \}\)\)/);
  assert.match(main, /webContents\.on\("will-navigate"/);
  for (const route of electron.routes) assert.match(appSource, new RegExp(`\"${escapeRegex(route)}\"`));

  assert.deepEqual(Object.keys(PROVIDERS).sort(), Object.keys(providers.providers).sort());
  for (const [id, expected] of Object.entries(providers.providers)) {
    for (const [key, value] of Object.entries(expected)) {
      // The frozen inventory predates the OCR-first amendment. Keep the old
      // provider fact readable while asserting that the retired direct-PDF
      // capability is absent from the live configuration.
      if (key === "supportsDirectPdf") {
        assert.equal(PROVIDERS[id][key], undefined, `${id}.supportsDirectPdf must stay retired`);
        continue;
      }
      assert.deepEqual(PROVIDERS[id][key], value, `${id}.${key} drift`);
    }
  }
});

test("baseline environment inventory covers example and source-only variables with executable ranges", async () => {
  const environment = await readJson("environment.json");
  const envExample = await readFile(new URL(".env.example", repo), "utf8");
  const source = await Promise.all([
    "electron/main.mjs", "electron/env-loader.mjs", "lib/config.mjs", "lib/ai-client.mjs", "lib/ocr/paddleocr.mjs", "lib/ocr/vision.mjs",
  ].map((path) => readFile(new URL(path, repo), "utf8"))).then((parts) => parts.join("\n"));
  const exampleNames = [...envExample.matchAll(/^([A-Z][A-Z0-9_]*)=/gm)].map((match) => match[1]);
  for (const name of exampleNames) assert.ok(environment.variables[name], `missing example variable ${name}`);
  for (const name of Object.keys(environment.variables)) assert.match(source + envExample, new RegExp(`\\b${name}\\b`), `unobserved variable ${name}`);
  assert.deepEqual(electronSettings({}), { maxBodyBytes: 80 * 1024 * 1024, maxConcurrentRecognitions: 1 });
  assert.deepEqual(electronSettings({ MAX_BODY_MB: "20", MAX_CONCURRENT_RECOGNITIONS: "16" }), { maxBodyBytes: 20 * 1024 * 1024, maxConcurrentRecognitions: 16 });
  assert.throws(() => electronSettings({ MAX_BODY_MB: "19" }), /20–200/);
  assert.throws(() => electronSettings({ MAX_CONCURRENT_RECOGNITIONS: "17" }), /1–16/);
  assert.equal(environment.variables.SLATESYNC_PROJECT_DIR.internal, true);
  assert.equal(environment.variables.OPENAI_API_KEY.secret, true);
  assert.equal(environment.variables.PADDLEOCR_PYTHON.redactWhenPublic, true);
  assert.equal(environment.releaseOnlySecrets.every((name) => !environment.variables[name]), true);
});

test("baseline SQLite inventory matches filenames, pragmas, columns, indexes, uniqueness, and foreign keys", async () => {
  const schema = await readJson("../persistence/schema.json");
  assert.deepEqual(SQLITE_FILENAMES, schema.filenames);
  assert.equal(LIBRARY_FORMAT_VERSION, schema.versions.libraryFormat);
  assert.equal(PROJECT_FORMAT_VERSION, schema.versions.projectFormat);
  assert.deepEqual(Object.keys(createTask()).sort(), [
    "accuracyMode", "createdAt", "customPrompt", "diagnosticSessionId", "durationMs", "editedRecords", "fileSize", "fileType", "filename", "id", "imageDataGroups", "model", "ocrSummary", "pageCount", "projectId", "projectSettingsSnapshot", "provider", "resolveCsvBase64", "resolveCsvEdits", "resolveCsvFilename", "resolveCsvTable", "result", "scenarioFingerprint", "scenarioId", "slateDirectoryName", "slateMetadata", "slateWarnings", "status", "updatedAt", "usage",
  ].sort());

  const tempDir = await mkdtemp(join(tmpdir(), "slatesync-baseline-contract-"));
  try {
    for (const [kind, expected] of [["library", schema.library], ["project", schema.project]]) {
      const { db } = openSlateDatabase(join(tempDir, kind), { kind, filename: schema.filenames[kind] });
      try {
        assert.deepEqual({
          journal_mode: db.pragma("journal_mode", { simple: true }),
          foreign_keys: db.pragma("foreign_keys", { simple: true }),
          busy_timeout: db.pragma("busy_timeout", { simple: true }),
        }, schema.pragmas);
        const tableNames = db.prepare("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ? ORDER BY name").all("table", "sqlite_%").map((row) => row.name);
        assert.deepEqual(tableNames, Object.keys(expected.tables).sort());
        for (const [table, columns] of Object.entries(expected.tables)) {
          const actual = db.prepare(`PRAGMA table_info(\"${table}\")`).all().map((row) => [row.name, row.type, row.notnull, row.dflt_value, row.pk]);
          assert.deepEqual(actual, columns, `${kind}.${table} columns drift`);
        }
        assert.deepEqual(actualIndexes(db, tableNames), [...expected.indexes].sort((a, b) => a.name.localeCompare(b.name)));
        assert.deepEqual(actualForeignKeys(db, tableNames), expected.foreignKeys);
      } finally {
        closeSlateDatabase(db);
      }
    }
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});
