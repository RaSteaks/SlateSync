// Registers every ipcMain.handle channel that the renderer's preload bridge
// (electron/preload.cjs) invokes. Each handler adapts a main-process service —
// recognition, model discovery, key/settings/task/diagnostic stores, file
// dialogs, slate directory scanning — into a JSON-safe IPC response, stripping
// pricing/cost fields before returning them to the client.
import { recognizeSlate } from "../lib/ai-client.mjs";
import {
  normalizeLegacyCompatibleOptions,
  PROVIDERS,
  publicConfig,
} from "../lib/config.mjs";
import {
  checkOpenAiCompatibleJsonSchema,
  probeCustomModels,
} from "../lib/model-capabilities.mjs";
import {
  bumpProviderRevision,
  isCustomProviderId,
  normalizeCustomProvider,
  newCustomProviderId,
  providerValidationError,
} from "../lib/custom-provider.mjs";
import { augmentPublicConfig, createProviderRegistry } from "../lib/provider-registry.mjs";
import {
  clearModelDiscoveryCache,
  discoverVisionModels,
  staticProviderModels,
} from "../lib/model-discovery.mjs";
import { clearRegisteredModels } from "../lib/model-catalog.mjs";
import {
  createSessionCapture,
} from "../lib/diagnostics.mjs";
import { checkPaddleOcr } from "../lib/ocr/paddleocr.mjs";
import { checkVisionOcr } from "../lib/ocr/vision.mjs";
import {
  listGlobalOverrides,
  normalizeGlobalSettingsPatch,
  normalizeOcrRoutingPatch,
  resolveGlobalSettingValues,
} from "./global-settings.mjs";
import {
  normalizeProjectSettings,
  projectSettingsFromWorkflow,
  validateProjectSettings,
} from "../lib/project-settings.mjs";
import { throwIfRecognitionCanceled } from "../lib/ocr/cancellation.mjs";

export function registerIpcHandlers(ipcMain, context) {
  const {
    workflowConfig,
    getWorkflowConfig = async () => workflowConfig,
    runtimeProviderKeys = new Map(),
    runtimeEnv,
    recognitionLimiter,
    settings,
    keyStore,
    fileDialogs,
    slateScanner,
    projectLibrary,
    projectRuntime,
    settingsStore,
    runtimeSettings,
    globalConfigStore,
    runtimeGlobalConfig = {},
    runtimeCustomProviders = [],
    refreshRuntimeSettings,
    libraryActions,
    logger,
    openLogDirectory,
    checkOcr = checkPaddleOcr,
    checkVision = checkVisionOcr,
    checkJsonSchema = checkOpenAiCompatibleJsonSchema,
    probeModels = probeCustomModels,
    recognize = recognizeSlate,
  } = context;
  // A project cannot transition to archived while any request owns writable
  // stores for it. The reservation also closes the inverse race where a write
  // starts after the archive request has passed its first check.
  const activeProjectWrites = new Map();
  const activeProjectReads = new Map();
  const projectReadDrains = new Map();
  const archivingProjects = new Set();
  const deletingProjects = new Set();
  const activeRecognitions = new Map();
  const activeModelProbes = new Map();
  let activeLibraryWrites = 0;
  let libraryTransferInProgress = false;

  function effectiveRuntimeEnv() {
    const env = { ...runtimeEnv() };
    // Main's production runtimeEnv already applies this map. Keeping the
    // fallback here makes the handler independently testable and preserves
    // key readiness immediately after a save in recovery contexts.
    for (const [providerId, apiKey] of providerKeyEntries(runtimeProviderKeys)) {
      const provider = PROVIDERS[providerId];
      if (provider && apiKey) env[provider.envKey] = apiKey;
    }
    return env;
  }

  function providerRegistry() {
    return createProviderRegistry({
      env: effectiveRuntimeEnv(),
      customProviders: runtimeCustomProviders,
      providerKeys: runtimeProviderKeys,
    });
  }

  function runtimeKeyConfigured(providerId) {
    if (typeof runtimeProviderKeys?.get === "function") {
      if (String(runtimeProviderKeys.get(providerId) || "").trim()) return true;
    } else if (String(runtimeProviderKeys?.[providerId] || "").trim()) {
      return true;
    }
    return providerId === "openai-compatible"
      ? Boolean(String(effectiveRuntimeEnv().OPENAI_COMPATIBLE_API_KEY || "").trim())
      : false;
  }

  async function saveGlobalSnapshot({ values = runtimeGlobalConfig, customProviders = runtimeCustomProviders } = {}) {
    if (!globalConfigStore) throw new Error("全局配置存储不可用");
    return globalConfigStore.save({
      // Snapshot candidates before handing them to the queued store so a
      // later renderer action cannot mutate an in-flight transaction.
      values: { ...values },
      customProviders: cloneCustomProviders(customProviders),
    });
  }

  async function commitCustomProviderState(nextProviders, nextKeys, { keysChanged = false } = {}) {
    const previousProviders = cloneCustomProviders(runtimeCustomProviders);
    const previousKeys = cloneRuntimeProviderKeys(runtimeProviderKeys);
    const providerSnapshot = cloneCustomProviders(nextProviders);
    const keySnapshot = cloneRuntimeProviderKeys(nextKeys);
    let globalSaved = false;
    try {
      // Publish the candidate configuration first; secrets remain in the
      // separate key store and both snapshots are committed before memory is
      // changed, so a failed save cannot create a phantom provider.
      await saveGlobalSnapshot({ customProviders: providerSnapshot });
      globalSaved = true;
      if (keysChanged && keyStore) await keyStore.save(keySnapshot);
    } catch (error) {
      if (globalSaved) {
        // A key-store failure happens after the config file was published. Try
        // to restore both durable snapshots, while preserving the original
        // error for the renderer.
        await saveGlobalSnapshot({ customProviders: previousProviders }).catch((rollbackError) => {
          logger?.error?.("settings", `自定义接口配置回滚失败 · ${rollbackError?.message || "未知错误"}`);
        });
        if (keysChanged && keyStore) {
          await keyStore.save(previousKeys).catch((rollbackError) => {
            logger?.error?.("settings", `自定义接口密钥回滚失败 · ${rollbackError?.message || "未知错误"}`);
          });
        }
      }
      replaceCustomProviders(runtimeCustomProviders, previousProviders);
      replaceRuntimeProviderKeys(runtimeProviderKeys, previousKeys);
      throw error;
    }
    replaceCustomProviders(runtimeCustomProviders, providerSnapshot);
    replaceRuntimeProviderKeys(runtimeProviderKeys, keySnapshot);
    return providerSnapshot;
  }

  ipcMain.handle("get-config", async () => {
    const config = publicConfig(effectiveRuntimeEnv(), await getWorkflowConfig(), {
      ocrAutoEnable: true,
    });
    const dynamicConfig = augmentPublicConfig(config, providerRegistry());
    return {
      ...dynamicConfig,
      upload: {
        ...config.upload,
        maxRequestBytes: settings.maxBodyBytes,
      },
    };
  });

  function publicGlobalSettings(restartRequired = false) {
    const env = effectiveRuntimeEnv();
    const registry = providerRegistry();
    return {
      values: resolveGlobalSettingValues(env),
      overrides: listGlobalOverrides(runtimeGlobalConfig),
      // This map contains presence flags only. Secret text never crosses IPC.
      keyConfigured: Object.fromEntries(registry.listProviderSummaries().map((provider) => [
        provider.id,
        registry.customRecord(provider.id)
          ? runtimeKeyConfigured(provider.id)
          : Boolean(String(env[PROVIDERS[provider.id]?.envKey] || "").trim()),
      ])),
      // The exact legacy ID is rendered in the fixed Provider section; only
      // UUID-backed records belong in the dedicated custom registry panel.
      customProviders: registry.customProviders.filter((provider) => isCustomProviderId(provider.id)).map((provider) =>
        publicCustomProvider(provider, runtimeKeyConfigured(provider.id), registry.getApiKey(provider.id))),
      restartRequired,
    };
  }

  ipcMain.handle("get-global-settings", async () => publicGlobalSettings());

  ipcMain.handle("save-global-settings", async (_event, body = {}) => {
    if (!globalConfigStore) throw new Error("全局配置存储不可用");
    const previousEnv = effectiveRuntimeEnv();
    const previous = { ...runtimeGlobalConfig };
    const patch = body?.reset === true
      ? {}
      : normalizeOcrRoutingPatch(
        normalizeGlobalSettingsPatch(body?.values || {}),
      );
    const next = body?.reset === true ? {} : { ...previous };
    for (const [key, value] of Object.entries(patch)) {
      if (value) next[key] = value;
      else delete next[key];
    }
    // Editing the legacy compatible fields is the migration boundary: keep a
    // fixed `openai-compatible` record so its project alias and Key continue
    // to resolve through the same dynamic registry on later launches.
    // Materialization edits only this candidate array. The live registry is
    // replaced below after the global-config save succeeds (copy-on-write).
    const candidateCustomProviders = cloneCustomProviders(runtimeCustomProviders);
    let legacyConnectionChanged = false;
    if (body?.reset === true) {
      legacyConnectionChanged = removeMaterializedLegacyCompatibleProvider(candidateCustomProviders);
    } else if (
      body?.reset !== true &&
      Object.keys(patch).some((key) => key.startsWith("OPENAI_COMPATIBLE_"))
    ) {
      legacyConnectionChanged = materializeLegacyCompatibleProvider(previousEnv, next, patch, candidateCustomProviders);
    }
    // Keep accepting the v1 test/embedding adapter which exposes save(values)
    // only; once any custom records exist, use the v2 envelope to preserve
    // them across ordinary setting edits.
    // A legacy record may be removed when its required Base URL/model is
    // cleared. In that case pass an explicit empty v2 registry; a values-only
    // save would intentionally preserve the store's cached customProviders.
    const saved = candidateCustomProviders.length || legacyConnectionChanged
      ? await globalConfigStore.save({ values: next, customProviders: cloneCustomProviders(candidateCustomProviders) })
      : await globalConfigStore.save(next);
    replaceCustomProviders(runtimeCustomProviders, candidateCustomProviders);
    if (legacyConnectionChanged) {
      clearModelDiscoveryCache("openai-compatible");
      clearRegisteredModels("openai-compatible");
    }
    for (const key of Object.keys(runtimeGlobalConfig)) delete runtimeGlobalConfig[key];
    const savedValues = saved?.values?.values && typeof saved.values.values === "object"
      ? saved.values.values
      : saved?.values || next;
    Object.assign(runtimeGlobalConfig, savedValues);

    // Keep the legacy first-run OCR wizard and the new global form pointed at
    // the same interpreter. The flags remain in settings.json for migration.
    const pathTouched = body?.reset === true
      ? Object.hasOwn(previous, "PADDLEOCR_PYTHON")
      : Object.hasOwn(patch, "PADDLEOCR_PYTHON");
    if (pathTouched && runtimeSettings) {
      const nextPythonPath = runtimeGlobalConfig.PADDLEOCR_PYTHON || "";
      const pathChanged = runtimeSettings.ocrPythonPath !== nextPythonPath;
      runtimeSettings.ocrPythonPath = nextPythonPath;
      // A generic global-form edit is not the validated OCR wizard flow. If
      // the interpreter changed or was cleared, make the next launch ask for
      // verification again instead of keeping a stale completion marker.
      if (pathChanged) {
        runtimeSettings.ocrSetupCompleted = false;
        runtimeSettings.ocrSetupSkipped = false;
      }
      await settingsStore?.save(runtimeSettings);
    }
    refreshRuntimeSettings?.();
    const nextEnv = effectiveRuntimeEnv();
    // The workflow provider is constructed once at startup. Other settings
    // refresh for later jobs, but a changed workflow path needs a relaunch.
    return publicGlobalSettings(
      String(previousEnv.SLATESYNC_CONFIG_PATH || "") !== String(nextEnv.SLATESYNC_CONFIG_PATH || ""),
    );
  });

  ipcMain.handle("list-projects", async () =>
    projectLibrary ? sanitizeProjects(await projectLibrary.listProjects({ includeArchived: true })) : [],
  );

  ipcMain.handle("get-library-info", async () =>
    projectLibrary ? sanitizeLibrary(await projectLibrary.getLibraryInfo()) : null,
  );

  ipcMain.handle("import-project-library", async () => {
    if (!libraryActions?.importLibrary) throw new Error("项目库导入不可用");
    return withLibraryTransfer(() => libraryActions.importLibrary());
  });

  ipcMain.handle("export-project-library", async () => {
    if (!libraryActions?.exportLibrary) throw new Error("项目库导出不可用");
    return withLibraryTransfer(() => libraryActions.exportLibrary());
  });

  ipcMain.handle("change-library-location", async () => {
    if (!libraryActions?.changeLocation) throw new Error("项目库位置选择不可用");
    return withLibraryTransfer(() => libraryActions.changeLocation());
  });

  ipcMain.handle("rename-library", async (_event, body) => {
    if (!libraryActions?.renameLibrary) throw new Error("项目库改名不可用");
    return withLibraryTransfer(() => libraryActions.renameLibrary(body?.name));
  });

  ipcMain.handle("create-project", async (_event, body) => {
    if (!projectLibrary) throw new Error("项目库不可用");
    return withLibraryWrite(async () => sanitizeProject(
      await projectLibrary.createProject({
        name: body?.name,
        description: body?.description,
        settings: body?.settings,
      }),
    ));
  });

  ipcMain.handle("load-project", async (_event, { id }) => {
    if (!projectLibrary) throw new Error("项目库不可用");
    return withProjectRead(id, async () =>
      sanitizeProject(await projectLibrary.getProject(id)),
    );
  });

  ipcMain.handle("update-project", async (_event, body) => {
    if (!projectLibrary) throw new Error("项目库不可用");
    return withProjectWrite(body?.id, async () =>
      sanitizeProject(await projectLibrary.updateProject(body?.id, {
        name: body?.name,
        description: body?.description,
        settings: body?.settings
          ? validateProjectSettings(body.settings)
          : undefined,
      })),
    );
  });

  ipcMain.handle("archive-project", async (_event, { id }) => {
    if (!projectLibrary) throw new Error("项目库不可用");
    assertLibraryWritable();
    if (archivingProjects.has(id) || deletingProjects.has(id)) throw projectDeleteBusy();
    if (Number(activeProjectWrites.get(id)) > 0) {
      throw projectWriteBusy();
    }
    archivingProjects.add(id);
    try {
      return sanitizeProject(await projectLibrary.archiveProject(id));
    } finally {
      archivingProjects.delete(id);
    }
  });

  ipcMain.handle("restore-project", async (_event, { id }) => {
    if (!projectLibrary) throw new Error("项目库不可用");
    if (deletingProjects.has(id)) throw projectDeleteBusy();
    return withLibraryWrite(async () =>
      sanitizeProject(await projectLibrary.restoreProject(id)),
    );
  });

  ipcMain.handle("delete-project", async (_event, { id }) => {
    if (!projectLibrary || !projectRuntime) throw new Error("项目库不可用");
    assertLibraryWritable();
    if (Number(activeProjectWrites.get(id)) > 0) throw projectWriteBusy("删除");
    if (archivingProjects.has(id) || deletingProjects.has(id)) throw projectDeleteBusy();
    deletingProjects.add(id);
    activeLibraryWrites += 1;
    try {
      // Block new access first, then let already-started readers release their
      // SQLite use before closeProject removes the cached runtime context.
      await waitForProjectReads(id);
      await projectRuntime.closeProject(id);
      return await projectLibrary.deleteProject(id);
    } finally {
      activeLibraryWrites -= 1;
      deletingProjects.delete(id);
    }
  });

  ipcMain.handle("list-scenarios", async (_event, body = {}) => {
    return withProjectRead(body.projectId, async () => {
      const context = await resolveProjectContext(body.projectId, { readOnly: true });
      return context.scenarioStore ? context.scenarioStore.listProfiles() : [];
    });
  });

  ipcMain.handle("load-scenario", async (_event, { projectId, id }) => {
    return withProjectRead(projectId, async () => {
      const context = await resolveProjectContext(projectId, { readOnly: true });
      if (!context.scenarioStore) throw new Error("场记结构存储不可用");
      return context.scenarioStore.getProfile(id);
    });
  });

  ipcMain.handle("import-scenario", async (_event, { projectId, profile }) => {
    return withProjectWrite(projectId, async () => {
      const context = await resolveProjectContext(projectId);
      if (!context.scenarioStore) throw new Error("场记结构存储不可用");
      return context.scenarioStore.importProfile(profile);
    });
  });

  ipcMain.handle("save-provider-key", async (_event, body) => {
    const providerId = String(body?.provider || "").trim();
    const provider = providerRegistry().resolveProvider(providerId) || PROVIDERS[providerId];
    if (!provider) {
      throw new Error("未知 API 服务商");
    }
    const apiKey = String(body?.apiKey || "").trim();
    const customIndex = runtimeCustomProviders.findIndex((candidate) => candidate.id === providerId);
    const nextKeys = cloneRuntimeProviderKeys(runtimeProviderKeys);
    if (apiKey) setRuntimeProviderKey(nextKeys, providerId, apiKey);
    else deleteRuntimeProviderKey(nextKeys, providerId);
    if (customIndex >= 0) {
      const custom = normalizeCustomProvider(runtimeCustomProviders[customIndex]);
      // Key changes invalidate explicit capability verification for this
      // connection revision, while retaining the project-level selection.
      const next = bumpProviderRevision(custom);
      const nextProviders = cloneCustomProviders(runtimeCustomProviders);
      nextProviders[customIndex] = next;
      await commitCustomProviderState(nextProviders, nextKeys, { keysChanged: true });
      clearModelDiscoveryCache(providerId);
      clearRegisteredModels(providerId);
    } else {
      // Built-in credentials have no provider record to publish, but still use
      // a candidate map so a failed key-store write leaves memory untouched.
      if (keyStore) await keyStore.save(nextKeys);
      replaceRuntimeProviderKeys(runtimeProviderKeys, nextKeys);
    }
    // A key change can alter both authentication and the provider's model
    // list. Invalidate short-lived discovery for every provider, including a
    // not-yet-materialized legacy connection, so a stale list is not reused.
    clearModelDiscoveryCache(providerId);
    clearRegisteredModels(providerId);
    return {
      provider: providerId,
      configured: provider.requiredEnv?.length
        ? provider.requiredEnv.every((key) => Boolean(String(effectiveRuntimeEnv()[key] || "").trim()))
        : true,
    };
  });

  ipcMain.handle("list-custom-providers", async () =>
    (() => {
      const registry = providerRegistry();
      return registry.customProviders.filter((provider) => isCustomProviderId(provider.id)).map((provider) =>
        publicCustomProvider(provider, runtimeKeyConfigured(provider.id), registry.getApiKey(provider.id)));
    })(),
  );

  ipcMain.handle("create-custom-provider", async (_event, body = {}) => {
    const candidate = normalizeCustomProvider({
      // Whitelist editable fields. Renderer input must never be able to seed
      // a verified cache or choose a revision that would bypass probing.
      // IDs are generated in Main so a renderer cannot impersonate the
      // legacy alias or another connection's namespace.
      id: newCustomProviderId(),
      name: body.name,
      baseUrl: body.baseUrl,
      transport: body.transport,
      jsonMode: body.jsonMode,
      imageDetail: body.imageDetail,
      manualModelIds: body.manualModelIds,
      revision: 1,
      capabilityCache: {},
    });
    assertUniqueProviderName(candidate.name, "", runtimeCustomProviders);
    if (runtimeCustomProviders.some((provider) => provider.id === candidate.id)) {
      throw providerValidationError("接口 ID 已存在");
    }
    const key = String(body.apiKey || "").trim();
    const nextProviders = [...cloneCustomProviders(runtimeCustomProviders), candidate];
    const nextKeys = cloneRuntimeProviderKeys(runtimeProviderKeys);
    if (key) setRuntimeProviderKey(nextKeys, candidate.id, key);
    await commitCustomProviderState(nextProviders, nextKeys, { keysChanged: Boolean(key) });
    const committed = runtimeCustomProviders.find((provider) => provider.id === candidate.id) || candidate;
    return publicCustomProvider(committed, runtimeKeyConfigured(committed.id), providerRegistry().getApiKey(committed.id));
  });

  ipcMain.handle("update-custom-provider", async (_event, body = {}) => {
    const providerId = String(body.id || body.providerId || "").trim();
    if (!isCustomProviderId(providerId)) {
      throw providerValidationError("旧版兼容接口请在固定 Provider 设置中管理", 400);
    }
    const index = runtimeCustomProviders.findIndex((provider) => provider.id === providerId);
    if (index < 0) throw providerValidationError("自定义接口不存在", 404);
    const current = normalizeCustomProvider(runtimeCustomProviders[index]);
    // As with creation, accept only editable connection fields. Persisted
    // revision/cache values remain Main-owned and are never renderer input.
    const nextInput = {
      id: providerId,
      name: body.name ?? current.name,
      baseUrl: body.baseUrl ?? current.baseUrl,
      transport: body.transport ?? current.transport,
      jsonMode: body.jsonMode ?? current.jsonMode,
      imageDetail: body.imageDetail ?? current.imageDetail,
      manualModelIds: body.manualModelIds ?? current.manualModelIds,
      revision: current.revision,
      capabilityCache: current.capabilityCache,
    };
    const nextBase = normalizeCustomProvider(nextInput);
    assertUniqueProviderName(nextBase.name, providerId, runtimeCustomProviders);
    // An empty key in an edit form means "keep the existing credential";
    // replacement/clear are explicit so a re-render cannot erase a secret.
    const suppliedKey = String(body.apiKey || "").trim();
    const clearApiKey = body.clearApiKey === true;
    // `replaceApiKey` can remain stale in a form draft. Only a non-empty key
    // replaces the secret; an empty key is a no-op unless clear was explicit.
    const replaceApiKey = suppliedKey.length > 0;
    const keyChanged = clearApiKey || replaceApiKey;
    const connectionChanged = ["baseUrl", "transport", "jsonMode", "imageDetail"].some((field) => current[field] !== nextBase[field]);
    const manualModelsChanged = JSON.stringify(current.manualModelIds) !== JSON.stringify(nextBase.manualModelIds);
    const next = connectionChanged || keyChanged || manualModelsChanged
      ? bumpProviderRevision(nextBase)
      : nextBase;
    const nextProviders = cloneCustomProviders(runtimeCustomProviders);
    nextProviders[index] = next;
    const nextKeys = cloneRuntimeProviderKeys(runtimeProviderKeys);
    if (clearApiKey) deleteRuntimeProviderKey(nextKeys, providerId);
    else if (replaceApiKey) setRuntimeProviderKey(nextKeys, providerId, suppliedKey);
    await commitCustomProviderState(nextProviders, nextKeys, { keysChanged: keyChanged });
    if (next.revision !== current.revision || manualModelsChanged) {
      clearModelDiscoveryCache(providerId);
      clearRegisteredModels(providerId);
    }
    const committed = runtimeCustomProviders[index] || next;
    return publicCustomProvider(committed, runtimeKeyConfigured(committed.id), providerRegistry().getApiKey(committed.id));
  });

  ipcMain.handle("delete-custom-provider", async (_event, body = {}) => {
    const providerId = String(body.id || body.providerId || "").trim();
    if (!isCustomProviderId(providerId)) {
      throw providerValidationError("旧版兼容接口不能从自定义接口列表删除", 400);
    }
    if (body.confirm !== true) throw providerValidationError("请确认删除接口", 400);
    const index = runtimeCustomProviders.findIndex((provider) => provider.id === providerId);
    if (index < 0) throw providerValidationError("自定义接口不存在", 404);
    // Stop in-flight network probes before dropping the record. Their late
    // results are revision-checked below, but aborting also releases sockets
    // promptly and keeps a deleted connection from doing hidden work.
    activeModelProbes.get(providerId)?.abort(new DOMException("接口已删除", "AbortError"));
    const nextProviders = cloneCustomProviders(runtimeCustomProviders);
    nextProviders.splice(index, 1);
    const nextKeys = cloneRuntimeProviderKeys(runtimeProviderKeys);
    deleteRuntimeProviderKey(nextKeys, providerId);
    await commitCustomProviderState(nextProviders, nextKeys, { keysChanged: true });
    clearModelDiscoveryCache(providerId);
    clearRegisteredModels(providerId);
    return { deleted: providerId };
  });

  ipcMain.handle("get-models", async (_event, { providerId, forceRefresh }) => {
    try {
      const registry = providerRegistry();
      const result = await discoverVisionModels(providerId, {
        forceRefresh: Boolean(forceRefresh),
        env: effectiveRuntimeEnv(),
        registry,
      });
      return clientModelDiscovery(result, registry.getApiKey(providerId));
    } catch (error) {
      if (Number(error.status) === 400) throw error;
      const fallbackRegistry = providerRegistry();
      const fallbackSecret = fallbackRegistry.getApiKey(providerId);
      const fallback = staticProviderModels(providerId, effectiveRuntimeEnv(), { registry: fallbackRegistry });
      const usableFallback = fallback.filter((model) => !["pending", "canceled", "failed", "unsupported"].includes(model.capabilityStatus));
      const pendingFallback = fallback.filter((model) => ["pending", "canceled"].includes(model.capabilityStatus));
      const failedFallback = fallback.filter((model) => model.capabilityStatus === "failed");
      return {
        provider: providerId,
        source: "static-fallback",
        refreshedAt: new Date().toISOString(),
        availableModelCount: null,
        visionModelCount: usableFallback.length,
        fixedModelCount: usableFallback.filter((model) => model.fixed).length,
        pendingModelCount: pendingFallback.length,
        pendingModels: pendingFallback.map((model) => withoutPricing(model, fallbackSecret)),
        failedModels: failedFallback.map((model) => withoutPricing(model, fallbackSecret)),
        failedModelCount: failedFallback.length,
        unsupportedModels: [],
        statusCounts: {
          usable: usableFallback.length,
          pending: pendingFallback.length,
          unsupported: 0,
          failed: failedFallback.length,
        },
        warning: redactSecretText(error.message || "无法读取实时模型列表", fallbackSecret),
        models: usableFallback.map((model) => withoutPricing(model, fallbackSecret)),
      };
    }
  });

  ipcMain.handle("check-compatible-json-schema", async () =>
    checkJsonSchema({ env: runtimeEnv() }),
  );

  ipcMain.handle("probe-custom-models", async (event, body = {}) => {
    const providerId = String(body.providerId || body.id || "").trim();
    if (!isCustomProviderId(providerId)) {
      throw providerValidationError("旧版兼容接口请使用固定 Provider 的兼容性检测", 400);
    }
    const registry = providerRegistry();
    const provider = registry.resolveProvider(providerId);
    if (!provider?.customProvider) throw providerValidationError("未知自定义接口", 404);
    if (activeModelProbes.has(providerId)) throw providerValidationError("该接口已有探针正在运行", 409);
    const controller = new AbortController();
    activeModelProbes.set(providerId, controller);
    try {
      const probeRevision = provider.revision;
      const apiKey = registry.getApiKey(providerId);
      const requestedModelIds = Array.isArray(body.modelIds)
        ? body.modelIds
        : provider.customProvider.manualModelIds;
      const requestedProbeIds = new Set(requestedModelIds
        .map((modelId) => String(modelId || "").trim())
        .filter((modelId) => /^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,219}$/.test(modelId)));
      const result = await probeModels({
        provider,
        apiKey,
        modelIds: requestedModelIds,
        signal: controller.signal,
        fetchImpl: body.fetchImpl,
        onProgress: (progress) => {
          if (typeof event?.sender?.send !== "function" || event.sender.isDestroyed?.()) return;
          const progressModel = String(progress?.model || "").trim();
          const safeProgressResult = sanitizeProbeOutcome(progress?.result, apiKey, requestedProbeIds);
          try {
            event.sender.send("model-probe-progress", {
              providerId,
              model: requestedProbeIds.has(progressModel) ? progressModel : "",
              completed: clampInteger(progress?.completed, 0, requestedProbeIds.size),
              total: requestedProbeIds.size,
              percent: clampInteger(progress?.percent, 0, 100),
              revision: probeRevision,
              ...(safeProgressResult ? { result: safeProgressResult } : {}),
            });
          } catch {
            // Progress is advisory; a closed/detached renderer must not make
            // the Main-side network probe fail.
          }
        },
      });
      // Probe implementations are injectable for tests and future transports;
      // whitelist their result fields at the Main boundary so a malformed
      // adapter cannot return credentials or forged cache metadata.
      const probeResults = Array.isArray(result?.results) ? result.results : [];
      const safeProbeResults = probeResults
        .map((item) => sanitizeProbeOutcome(item, apiKey, requestedProbeIds))
        .filter(Boolean);
      const safeResult = {
        canceled: Boolean(result?.canceled || controller.signal.aborted),
        revision: probeRevision,
        results: safeProbeResults,
        completed: clampInteger(result?.completed, safeProbeResults.length, requestedProbeIds.size),
        total: requestedProbeIds.size,
      };
      const record = runtimeCustomProviders.find((candidate) => candidate.id === providerId);
      // Persist every model that actually completed, even when the batch was
      // canceled part-way through. Successful/failed entries are revision
      // scoped; canceled entries remain pending on the next discovery and do
      // not become selectable by accident.
      // If the endpoint/key was edited while requests were in flight, late
      // responses belong to the old revision and must never repopulate the
      // new cache. The UI can explicitly retry against the new connection.
      if (record && Number(record.revision) === Number(probeRevision)) {
        // Probe results are revision-scoped cache data, not user-entered model
        // configuration. Build a candidate snapshot so a failed global save
        // cannot mutate the live record or append IDs to manualModelIds.
        const nextProviders = cloneCustomProviders(runtimeCustomProviders);
        const nextRecord = nextProviders.find((candidate) => candidate.id === providerId);
        nextRecord.capabilityCache ||= {};
        for (const item of safeResult.results) {
          if (["verified", "failed", "canceled"].includes(item.capabilityStatus)) {
            nextRecord.capabilityCache[item.model] = {
              status: item.capabilityStatus,
              revision: probeRevision,
              checkedAt: item.checkedAt,
              transport: item.transport,
              message: item.message,
              capabilitySource: "synthetic image probe",
            };
          }
        }
        await saveGlobalSnapshot({ customProviders: nextProviders });
        replaceCustomProviders(runtimeCustomProviders, nextProviders);
        // A successful probe changes both the discovery classification and
        // the recognition registration; neither may remain cached as stale.
        clearModelDiscoveryCache(providerId);
        clearRegisteredModels(providerId);
      }
      return safeResult;
    } finally {
      activeModelProbes.delete(providerId);
    }
  });

  ipcMain.handle("cancel-custom-model-probe", async (_event, body = {}) => {
    const providerId = String(body.providerId || body.id || "").trim();
    const controller = activeModelProbes.get(providerId);
    if (!controller) return { canceled: false };
    controller.abort(new DOMException("模型探针已取消", "AbortError"));
    return { canceled: true };
  });

  ipcMain.handle("recognize", async (event, body) => {
    const release = recognitionLimiter.acquire();
    const controller = new AbortController();
    const requestedProjectId = String(body?.projectId || "");
    const activeRecognition = createActiveRecognition(controller);
    addActiveRecognition(requestedProjectId, activeRecognition);
    const capture = createSessionCapture();
    let projectContext = null;
    let activeProjectId = null;
    try {
      if (!requestedProjectId) throw new Error("请先选择项目");
      // Acquire the write lease before resolving the runtime. This closes the
      // gap where deletion could close a context while recognition was opening
      // its SQLite-backed stores.
      beginProjectWrite(requestedProjectId);
      activeProjectId = requestedProjectId;
      const workflow = await getWorkflowConfig();
      projectContext = await resolveProjectContext(body?.projectId);
      const projectSettings = normalizeProjectSettings(
        projectContext.project?.settings || projectSettingsFromWorkflow(workflow),
        projectSettingsFromWorkflow(workflow),
      );
      const input = recognitionInput(body, workflow, projectSettings);
      if (projectContext.project) {
        capture.session.projectId = projectContext.project.id;
        capture.session.projectSettingsSnapshot = projectSettings;
      }
      // The local log mirrors the full run (start, every progress event,
      // outcome) so any recognition can be audited after the fact. Logging is
      // fire-and-forget and failure-swallowing; it must never delay or break
      // the recognition itself.
      logger?.info(
        "recognition",
        `识别开始 · ${input.filename || "未命名文件"} · ${input.providerId}/${input.modelId}`,
        {
          provider: input.providerId,
          model: input.modelId,
          pageCount: input.pageCount,
        },
      );
      const result = await recognize(input, {
        env: runtimeEnv(),
        providerRegistry: providerRegistry(),
        ocrAutoEnable: true,
        projectScopedOutput: Boolean(projectContext.project),
        scenarioStore: projectContext.scenarioStore,
        onProgress: (progressEvent) => {
          logRecognitionProgress(logger, progressEvent);
          if (!event.sender.isDestroyed()) {
            event.sender.send("recognition-progress", progressEvent);
          }
        },
        capture,
        signal: controller.signal,
      });
      // Recognition can be stopped after the provider responds but before the
      // Main-process persistence tail starts. Do not turn that late stop into
      // a completed task or a success response for the Renderer.
      throwIfRecognitionCanceled(controller.signal);
      const diagnosticsStore = projectContext.diagnostics;
      const taskStoreForProject = projectContext.taskStore;
      const sessionId = diagnosticsStore
        ? await diagnosticsStore.saveSession(capture.session)
        : null;
      throwIfRecognitionCanceled(controller.signal);
      const completedTask = {
        projectId: projectContext.project?.id || body?.projectId || null,
        projectSettingsSnapshot: projectSettings,
        status: "completed",
        filename: input.filename,
        pageCount: result.pageCount,
        provider: result.provider,
        model: result.model,
        scenarioId: result.scenario?.id || null,
        scenarioMatch: result.scenario?.match || null,
        scenarioFingerprint: result.scenario?.fingerprint || null,
        customPrompt: input.customPrompt || null,
        accuracyMode: result.accuracyMode,
        result: result.result,
        // Replace a draft's empty edit buffer with the newly recognized rows;
        // listTasks otherwise prefers the stale empty array over result data.
        editedRecords: result.result.records,
        usage: result.usage,
        durationMs: result.durationMs,
        ocrSummary: result.ocr,
        diagnosticSessionId: sessionId,
      };
      // Recognition is the completion phase of the current draft. Updating by
      // its project-scoped ID keeps one logical task and preserves draft-only
      // inputs; a run without a draft remains a legitimate new task.
      const taskId = taskStoreForProject
        ? body?.taskId
          ? await taskStoreForProject.updateTask(body.taskId, completedTask)
          : await taskStoreForProject.saveTask(completedTask)
        : null;
      throwIfRecognitionCanceled(controller.signal);
      if (taskId && projectContext.project && projectLibrary) {
        await projectLibrary.touchProjectActivity(projectContext.project.id);
      }
      const recordCount = result.result?.records?.length ?? 0;
      logger?.info(
        "recognition",
        `识别完成 · ${recordCount} 条记录 · ${result.provider}/${result.model} · 耗时 ${(result.durationMs / 1000).toFixed(1)}s`,
        {
          provider: result.provider,
          model: result.model,
          records: recordCount,
          durationMs: result.durationMs,
        },
      );
      return {
        ...clientRecognitionResult(result),
        // The renderer formats the immediate result with this exact snapshot,
        // rather than whichever project happens to be selected when it returns.
        projectId: projectContext.project?.id || null,
        projectSettingsSnapshot: projectContext.project ? projectSettings : null,
        lastRecognitionDefaults: projectContext.project
          ? {
              providerId: result.provider,
              modelId: result.model,
              customPrompt: input.customPrompt || "",
            }
          : null,
        diagnosticSessionId: sessionId,
        taskId,
      };
    } catch (error) {
      // Provider gateways occasionally echo an Authorization token in an
      // error message. Redact it before the diagnostic snapshot, local log,
      // or Result envelope can observe the failure.
      const providerSecret = (() => {
        try {
          return providerRegistry().getApiKey(String(body?.provider || body?.providerId || ""));
        } catch {
          return "";
        }
      })();
      const safeError = redactErrorSecret(error, providerSecret);
      capture.setError(safeError);
      // A user-requested stop is a normal outcome, not a failure: keep the two
      // distinguishable in the log so reviews do not read stops as crashes.
      if (controller.signal.aborted || safeError?.code === "RECOGNITION_CANCELED") {
        logger?.warn("recognition", `识别已停止 · ${body?.filename || "未命名文件"}`);
      } else {
        logger?.error("recognition", `识别失败 · ${safeError?.message || String(safeError)}`);
      }
      if (activeProjectId && projectContext?.diagnostics) {
        await projectContext.diagnostics.saveSession(capture.session).catch(() => {});
      }
      throw safeError;
    } finally {
      removeActiveRecognition(requestedProjectId, activeRecognition);
      try {
        if (activeProjectId) endProjectWrite(activeProjectId);
        release();
      } finally {
        // cancel-recognition waits for this signal, so it cannot claim the job
        // stopped while its write lease or recognition limiter is still held.
        // Resolve even if a defensive cleanup hook fails, otherwise the stop
        // IPC could wait forever after the recognition promise has settled.
        activeRecognition.resolveSettled();
      }
    }
  });

  ipcMain.handle("cancel-recognition", async (_event, body = {}) => {
    const projectId = String(body.projectId || "");
    const recognitions = [...(activeRecognitions.get(projectId) || [])];
    if (!recognitions.length) return { canceled: false };
    logger?.warn("recognition", `请求停止识别 · ${projectId}`);
    for (const recognition of recognitions) {
      recognition.controller.abort(new DOMException("识别已停止", "AbortError"));
    }
    // An AbortController only requests cancellation. Waiting for each run's
    // finalizer makes the IPC acknowledgement truthful for local OCR, model
    // fetches, SQLite persistence, and the per-project write lease.
    await Promise.allSettled(recognitions.map((recognition) => recognition.settled));
    return { canceled: true };
  });

  ipcMain.handle("save-file", async (_event, { defaultFilename, data }) => {
    if (!fileDialogs) throw new Error("文件对话框不可用");
    return fileDialogs.saveFile(defaultFilename, data);
  });

  ipcMain.handle("select-directory", async () => {
    if (!fileDialogs) throw new Error("文件对话框不可用");
    return fileDialogs.selectDirectory();
  });

  ipcMain.handle(
    "scan-slate-directory",
    async (_event, { dirPath, expectedKeys, maxDepth }) => {
      if (!slateScanner) throw new Error("目录扫描不可用");
      return slateScanner.scan(dirPath, { expectedKeys, maxDepth });
    },
  );

  ipcMain.handle("list-tasks", async (_event, body = {}) => {
    return withProjectRead(body.projectId, async () => {
      const context = await resolveProjectContext(body.projectId, { readOnly: true });
      // Keep the preload contract compact: task lists cross IPC as arrays.
      if (!context.taskStore) return [];
      return context.taskStore.listTasks();
    });
  });

  ipcMain.handle("load-task", async (_event, { projectId, id }) => {
    return withProjectRead(projectId, async () => {
      const context = await resolveProjectContext(projectId, { readOnly: true });
      if (!context.taskStore) throw new Error("任务存储不可用");
      return context.taskStore.loadTask(id);
    });
  });

  ipcMain.handle("save-task", async (_event, body) => {
    const task = body?.task || body;
    const projectId = body?.projectId || task?.projectId;
    return withProjectWrite(projectId, async () => {
      const context = await resolveProjectContext(projectId);
      if (!context.taskStore) throw new Error("任务存储不可用");
      const resolvedProjectId = context.project?.id || projectId;
      const safeTask = { ...task };
      if (context.project || projectId || task?.projectId) {
        safeTask.projectId = resolvedProjectId || task.projectId;
      }
      const taskId = safeTask?.id
        ? await context.taskStore.updateTask(safeTask.id, safeTask)
        : await context.taskStore.saveTask(safeTask);
      if (context.project && projectLibrary) {
        await projectLibrary.touchProjectActivity(context.project.id);
      }
      return taskId;
    });
  });

  ipcMain.handle("delete-task", async (_event, { projectId, id }) => {
    return withProjectWrite(projectId, async () => {
      const context = await resolveProjectContext(projectId);
      if (!context.taskStore) throw new Error("任务存储不可用");
      const resolvedProjectId = context.project?.id || projectId;
      await context.taskStore.deleteTask(id);
      if (context.project && projectLibrary) {
        await projectLibrary.touchProjectActivity(context.project.id);
      }
      return { deleted: id };
    });
  });

  ipcMain.handle("get-ocr-settings", async () => {
    const envPythonPath = effectiveRuntimeEnv().PADDLEOCR_PYTHON;
    return {
      // Include .env/OS fallbacks in the display while retaining the legacy
      // settings-store fallback for isolated test/recovery contexts.
      pythonPath: envPythonPath || runtimeSettings?.ocrPythonPath || "",
      setupCompleted: Boolean(runtimeSettings?.ocrSetupCompleted),
      setupSkipped: Boolean(runtimeSettings?.ocrSetupSkipped),
    };
  });

  ipcMain.handle("save-ocr-settings", async (_event, body) => {
    if (!settingsStore) throw new Error("设置存储不可用");
    let nextSettings;
    if (body?.skip === true) {
      nextSettings = {
        ...runtimeSettings,
        ocrPythonPath: "",
        ocrSetupCompleted: false,
        ocrSetupSkipped: true,
      };
    } else {
      const pythonPath = String(body?.pythonPath ?? "").trim();
      if (!pythonPath) throw new Error("请先填写 PaddleOCR Python 环境路径。");

      // Validate before changing memory or disk, so a failed check cannot make
      // an unusable interpreter look like a completed OCR setup.
      const checkResult = await checkOcr({
        pythonPath,
        env: effectiveRuntimeEnv(),
      });
      if (!checkResult?.ok) {
        throw new Error(
          checkResult?.error?.message || "PaddleOCR 检测失败，未保存设置。",
        );
      }
      nextSettings = {
        ...runtimeSettings,
        ocrPythonPath: pythonPath,
        ocrSetupCompleted: true,
        ocrSetupSkipped: false,
      };
    }
    const savedSettings = await settingsStore.save(nextSettings);
    Object.assign(runtimeSettings, savedSettings || nextSettings);
    if (globalConfigStore) {
      const nextGlobalConfig = { ...runtimeGlobalConfig };
      if (body?.skip === true) delete nextGlobalConfig.PADDLEOCR_PYTHON;
      else nextGlobalConfig.PADDLEOCR_PYTHON = runtimeSettings.ocrPythonPath;
      const savedGlobalConfig = await globalConfigStore.save(nextGlobalConfig);
      for (const key of Object.keys(runtimeGlobalConfig)) delete runtimeGlobalConfig[key];
      Object.assign(runtimeGlobalConfig, savedGlobalConfig?.values || nextGlobalConfig);
    }
    refreshRuntimeSettings?.();
    return {
      pythonPath: runtimeSettings.ocrPythonPath,
      setupCompleted: runtimeSettings.ocrSetupCompleted,
      setupSkipped: runtimeSettings.ocrSetupSkipped,
    };
  });

  ipcMain.handle("check-ocr", async (_event, body) =>
    checkOcr({
      pythonPath: String(body?.pythonPath ?? "").trim(),
      env: effectiveRuntimeEnv(),
    }),
  );

  ipcMain.handle("check-vision-ocr", async () =>
    checkVision({ env: runtimeEnv() }),
  );

  // Read-only view over the local application log. The handler degrades to an
  // empty result when logging is not wired (unit contexts, degraded start) so
  // the viewer stays usable instead of surfacing an error for advisory data.
  ipcMain.handle("logs-read", async (_event, body = {}) => {
    if (!logger?.readEntries) return { entries: [], hasMore: false };
    return logger.readEntries({
      limit: body?.limit,
      level: body?.level,
      category: typeof body?.category === "string" && body.category
        ? body.category
      : undefined,
    });
  });

  // The renderer never receives the log path. Main creates/reveals its own
  // private directory through the OS opener, keeping filesystem access out of
  // the sandboxed Renderer and making the action safe before the first log.
  ipcMain.handle("logs-open-directory", async () => {
    if (!logger?.logsDir || !openLogDirectory) throw new Error("本地日志目录不可用");
    return openLogDirectory(logger.logsDir);
  });

  async function resolveProjectContext(projectId, { readOnly = false } = {}) {
    if (!projectRuntime) throw new Error("项目运行时不可用");
    if (!projectId) throw new Error("请先选择项目");
    if (deletingProjects.has(projectId)) throw projectDeleteBusy();
    return projectRuntime.get(projectId, { allowArchived: readOnly });
  }

  function beginProjectRead(projectId) {
    if (!projectId) throw new Error("请先选择项目");
    if (deletingProjects.has(projectId)) throw projectDeleteBusy();
    activeProjectReads.set(
      projectId,
      Number(activeProjectReads.get(projectId) || 0) + 1,
    );
  }

  function endProjectRead(projectId) {
    const remaining = Number(activeProjectReads.get(projectId) || 0) - 1;
    if (remaining > 0) {
      activeProjectReads.set(projectId, remaining);
      return;
    }
    activeProjectReads.delete(projectId);
    const drains = projectReadDrains.get(projectId);
    projectReadDrains.delete(projectId);
    drains?.forEach((resolve) => resolve());
  }

  async function waitForProjectReads(projectId) {
    if (!Number(activeProjectReads.get(projectId))) return;
    await new Promise((resolve) => {
      const drains = projectReadDrains.get(projectId) || [];
      drains.push(resolve);
      projectReadDrains.set(projectId, drains);
    });
  }

  async function withProjectRead(projectId, operation) {
    beginProjectRead(projectId);
    try {
      return await operation();
    } finally {
      endProjectRead(projectId);
    }
  }

  function beginProjectWrite(projectId) {
    if (!projectId) throw new Error("请先选择项目");
    assertLibraryWritable();
    if (archivingProjects.has(projectId)) throw projectArchiveBusy();
    if (deletingProjects.has(projectId)) throw projectDeleteBusy();
    activeProjectWrites.set(
      projectId,
      Number(activeProjectWrites.get(projectId) || 0) + 1,
    );
  }

  function endProjectWrite(projectId) {
    const remaining = Number(activeProjectWrites.get(projectId) || 0) - 1;
    if (remaining > 0) activeProjectWrites.set(projectId, remaining);
    else activeProjectWrites.delete(projectId);
  }

  async function withProjectWrite(projectId, operation) {
    beginProjectWrite(projectId);
    try {
      return await operation();
    } finally {
      endProjectWrite(projectId);
    }
  }

  async function withLibraryWrite(operation) {
    assertLibraryWritable();
    activeLibraryWrites += 1;
    try {
      return await operation();
    } finally {
      activeLibraryWrites -= 1;
    }
  }

  function assertLibraryWritable() {
    if (libraryTransferInProgress) {
      const error = new Error("项目库正在导入、导出或切换位置，请稍候");
      error.code = "LIBRARY_BUSY";
      throw error;
    }
  }

  async function withLibraryTransfer(operation) {
    assertLibraryWritable();
    if (activeLibraryWrites || activeProjectWrites.size || archivingProjects.size || deletingProjects.size) {
      const error = new Error("项目库仍有任务正在写入，完成后才能继续");
      error.code = "LIBRARY_BUSY";
      throw error;
    }
    libraryTransferInProgress = true;
    let restartRequired = false;
    try {
      const result = await operation();
      restartRequired = Boolean(result?.restartRequired);
      return result;
    } finally {
      // A library switch closes the active databases and immediately relaunches
      // Electron. Keep writes blocked during that short shutdown window.
      if (!restartRequired) libraryTransferInProgress = false;
    }
  }

  function createActiveRecognition(controller) {
    let resolveSettled;
    const settled = new Promise((resolve) => { resolveSettled = resolve; });
    return { controller, settled, resolveSettled };
  }

  function addActiveRecognition(projectId, recognition) {
    const recognitions = activeRecognitions.get(projectId) || new Set();
    recognitions.add(recognition);
    activeRecognitions.set(projectId, recognitions);
  }

  function removeActiveRecognition(projectId, recognition) {
    const recognitions = activeRecognitions.get(projectId);
    if (!recognitions) return;
    recognitions.delete(recognition);
    if (!recognitions.size) activeRecognitions.delete(projectId);
  }
}

function projectWriteBusy(action = "归档") {
  const error = new Error(`项目正在写入数据，完成后才能${action}`);
  error.code = "PROJECT_BUSY";
  return error;
}

function projectDeleteBusy() {
  const error = new Error("项目正在归档或删除，无法继续操作");
  error.code = "PROJECT_BUSY";
  return error;
}

function projectArchiveBusy() {
  const error = new Error("项目正在归档，无法写入数据");
  error.code = "PROJECT_BUSY";
  return error;
}

function recognitionInput(body, workflowConfig, projectSettings) {
  if (Object.hasOwn(body || {}, "pdfDataUrl")) {
    const error = new Error("原始 PDF 直传已停用，请先在本地将 PDF 转为逐页图片后再识别。");
    error.status = 400;
    error.providerError = false;
    throw error;
  }
  const settings = projectSettings || projectSettingsFromWorkflow(workflowConfig);
  return {
    // Provider/model/prompt are task defaults selected in the workspace. The
    // remaining recognition and Resolve rules stay authoritative per project.
    providerId: body.provider || settings.providerId,
    modelId: body.model || settings.modelId,
    imageDataUrl: body.imageDataUrl,
    imageDataUrls: body.imageDataUrls,
    imageDataGroups: body.imageDataGroups,
    pageCount: body.pageCount,
    filename: body.filename,
    // Electron accuracy is project-owned; the workspace mirrors this value
    // and intentionally cannot override it for a single task.
    accuracyMode: settings.accuracyMode,
    scenarioId: settings.scenarioId || body.scenarioId,
    customPrompt: Object.hasOwn(body, "customPrompt")
      ? body.customPrompt
      : settings.customPrompt,
    slateCsvRecords: body.slateCsvRecords || null,
    fieldFormats: settings.resolve.fieldFormats,
    comments: settings.resolve.comments,
  };
}

function sanitizeProjects(projects) {
  return projects.map(sanitizeProject);
}

function sanitizeProject(project) {
  if (!project) return null;
  const safe = { ...project };
  delete safe.directoryPath;
  return safe;
}

function sanitizeLibrary(library) {
  if (!library) return null;
  return {
    id: library.id,
    name: library.name,
    formatVersion: library.formatVersion,
    path: library.path,
  };
}

function clientModelDiscovery(result, secret = "") {
  return {
    ...result,
    models: (result.models || []).map((model) => withoutPricing(model, secret)),
    pendingModels: (result.pendingModels || []).map((model) => withoutPricing(model, secret)),
    failedModels: (result.failedModels || []).map((model) => withoutPricing(model, secret)),
  };
}

function withoutPricing(model, secret = "") {
  const publicModel = { ...model };
  delete publicModel.price;
  delete publicModel.prices;
  delete publicModel.pricePerMillion;
  // Keep price computation and raw price timestamps in Main. Renderer DTOs
  // receive only the separate rating provenance/date fields.
  delete publicModel.priceUpdatedAt;
  if (publicModel.capabilityMessage) {
    publicModel.capabilityMessage = redactSecretText(publicModel.capabilityMessage, secret);
  }
  return publicModel;
}

function publicCustomProvider(provider, keyConfigured = false, secret = "") {
  return {
    id: provider.id,
    name: provider.name,
    label: provider.name,
    baseUrl: provider.baseUrl,
    transport: provider.transport,
    jsonMode: provider.jsonMode,
    imageDetail: provider.imageDetail,
    manualModelIds: [...provider.manualModelIds],
    revision: provider.revision,
    keyConfigured,
    capabilityCache: Object.fromEntries(Object.entries(provider.capabilityCache || {}).map(([modelId, value]) => {
      const safeMessage = redactSecretText(value.message, secret);
      return [modelId, {
        status: value.status,
        revision: value.revision,
        checkedAt: redactSecretText(value.checkedAt, secret).slice(0, 80) || null,
        capabilitySource: redactSecretText(value.capabilitySource, secret).slice(0, 120),
        // Capability errors are normally redacted by the probe itself. Keep a
        // second Main-boundary redaction for imported snapshots or injected
        // probe implementations that may have echoed the credential.
        ...(safeMessage ? { message: safeMessage } : {}),
      }];
    })),
  };
}

function assertUniqueProviderName(name, exceptId = "", providers = []) {
  const normalized = String(name || "").trim().toLowerCase();
  const duplicate = providers.some((provider) =>
    provider.id !== exceptId && String(provider.name || provider.label || "").trim().toLowerCase() === normalized,
  );
  if (duplicate) throw providerValidationError("接口名称已存在");
}

function materializeLegacyCompatibleProvider(previousEnv, nextValues, patch, providers) {
  const field = (key) => Object.hasOwn(patch, key)
    ? String(nextValues[key] || "").trim()
    : String(previousEnv[key] || "").trim();
  const baseUrl = field("OPENAI_COMPATIBLE_BASE_URL");
  const modelId = field("OPENAI_COMPATIBLE_MODEL");
  const index = providers.findIndex((provider) => provider.id === "openai-compatible");
  if (!baseUrl || !modelId) {
    if (index >= 0) {
      // Clearing either required legacy field means the fixed compatibility
      // connection is no longer configured. Remove only that materialized
      // record; its private key remains available if the user configures it
      // again, while UUID custom providers are untouched.
      providers.splice(index, 1);
      return true;
    }
    return false;
  }
  const current = index >= 0 ? normalizeCustomProvider(providers[index]) : null;
  const compatibleOptions = normalizeLegacyCompatibleOptions(
    field("OPENAI_COMPATIBLE_API_MODE") || "chat-completions",
    field("OPENAI_COMPATIBLE_JSON_MODE") || "json_object",
  );
  const candidate = normalizeCustomProvider({
    ...(current || {}),
    id: "openai-compatible",
    // A user-created UUID provider may already use the historical display
    // name. Keep the fixed legacy connection distinct without rejecting a
    // valid first-run migration.
    name: current?.name || uniqueLegacyProviderName(providers),
    baseUrl,
    transport: compatibleOptions.transport,
    jsonMode: compatibleOptions.jsonMode,
    imageDetail: field("OPENAI_COMPATIBLE_IMAGE_DETAIL") || "high",
    manualModelIds: [modelId],
  });
  if (!current) {
    providers.push(candidate);
    return true;
  }
  const connectionChanged = ["baseUrl", "transport", "jsonMode", "imageDetail", "manualModelIds"]
    .some((key) => JSON.stringify(current[key]) !== JSON.stringify(candidate[key]));
  providers[index] = connectionChanged ? bumpProviderRevision(candidate) : candidate;
  return connectionChanged;
}

function removeMaterializedLegacyCompatibleProvider(providers) {
  const index = providers.findIndex((provider) => provider.id === "openai-compatible");
  if (index < 0) return false;
  // Reset restores .env/default resolution; the v2 UUID registry remains
  // untouched, so only the compatibility record created by this migration is
  // removed from the persisted custom-provider envelope.
  providers.splice(index, 1);
  return true;
}

function uniqueLegacyProviderName(providers) {
  const base = "OpenAI 兼容 API";
  const used = new Set((providers || []).map((provider) =>
    String(provider.name || provider.label || "").trim().toLowerCase(),
  ));
  if (!used.has(base.toLowerCase())) return base;
  for (let index = 2; index < 1000; index += 1) {
    const candidate = `${base} · 旧配置 ${index}`;
    if (!used.has(candidate.toLowerCase())) return candidate.slice(0, 60);
  }
  return `${base} · 旧配置`.slice(0, 60);
}

function clientRecognitionResult(result) {
  const publicResult = { ...result };
  delete publicResult.cost;
  if (publicResult.usage && typeof publicResult.usage === "object") {
    publicResult.usage = { ...publicResult.usage };
    delete publicResult.usage.cost;
  }
  return publicResult;
}

function redactErrorSecret(error, secret) {
  const normalizedSecret = String(secret || "").trim();
  if (!normalizedSecret || !error) return error;
  const replace = (value) => String(value || "").split(normalizedSecret).join("[已隐藏]");
  const message = replace(error.message || error);
  const stack = error.stack ? replace(error.stack) : undefined;
  if (message === String(error.message || error) && stack === error.stack) return error;
  const safe = new Error(message);
  safe.name = error.name || "Error";
  if (stack) safe.stack = stack;
  // Preserve the status/code contract while keeping the original Error object
  // out of Renderer-facing diagnostics once a secret was detected.
  for (const key of ["status", "code", "providerError", "retryable"]) {
    if (key in error) safe[key] = error[key];
  }
  return safe;
}

function redactSecretText(value, secret) {
  const message = String(value || "");
  const normalizedSecret = String(secret || "").trim();
  return normalizedSecret ? message.split(normalizedSecret).join("[已隐藏]") : message;
}

function cloneCustomProviders(providers) {
  return (providers || []).map((provider) => ({
    ...provider,
    manualModelIds: Array.isArray(provider?.manualModelIds)
      ? [...provider.manualModelIds]
      : [],
    capabilityCache: provider?.capabilityCache && typeof provider.capabilityCache === "object"
      ? Object.fromEntries(Object.entries(provider.capabilityCache).map(([modelId, value]) => [
        modelId,
        value && typeof value === "object" ? { ...value } : value,
      ]))
      : {},
  }));
}

function replaceCustomProviders(target, next) {
  target.splice(0, target.length, ...cloneCustomProviders(next));
}

function sanitizeProbeOutcome(value, secret, allowedModels) {
  if (!value || typeof value !== "object") return null;
  const model = String(value.model || "").trim();
  if (!model || !allowedModels?.has(model)) return null;
  const canceled = value.capabilityStatus === "canceled";
  // The boolean is the probe adapter's actual assertion. Do not let an
  // injected/malformed adapter forge a cache hit by merely labelling a result
  // `capabilityStatus: verified`.
  const supported = !canceled && value.supported === true;
  const capabilityStatus = canceled
    ? "canceled"
    : supported
      ? "verified"
      : "failed";
  const status = Number(value.status);
  return {
    supported,
    model,
    transport: value.transport === "responses" ? "responses" : "chat-completions",
    status: Number.isInteger(status) && status >= 100 && status <= 599 ? status : null,
    checkedAt: typeof value.checkedAt === "string"
      ? redactSecretText(value.checkedAt, secret).slice(0, 80)
      : new Date().toISOString(),
    message: redactSecretText(value.message, secret).slice(0, 500),
    capabilityStatus,
  };
}

function clampInteger(value, minimum, maximum) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return minimum;
  return Math.min(maximum, Math.max(minimum, Math.round(numeric)));
}

function providerKeyEntries(value) {
  if (typeof value?.entries === "function") return value.entries();
  if (value && typeof value === "object") return Object.entries(value);
  return [];
}

function cloneRuntimeProviderKeys(value) {
  return new Map(providerKeyEntries(value));
}

function replaceRuntimeProviderKeys(target, next) {
  const entries = [...providerKeyEntries(next)];
  if (typeof target?.clear === "function" && typeof target?.set === "function") {
    target.clear();
    for (const [providerId, apiKey] of entries) target.set(providerId, apiKey);
    return;
  }
  if (target && typeof target === "object") {
    for (const providerId of Object.keys(target)) delete target[providerId];
    for (const [providerId, apiKey] of entries) target[providerId] = apiKey;
  }
}

function setRuntimeProviderKey(store, providerId, apiKey) {
  if (typeof store?.set === "function") store.set(providerId, apiKey);
  else if (store && typeof store === "object") store[providerId] = apiKey;
}

function deleteRuntimeProviderKey(store, providerId) {
  if (typeof store?.delete === "function") store.delete(providerId);
  else if (store && typeof store === "object") delete store[providerId];
}

/**
 * Keep the progress stream in one logging tee next to the existing IPC send.
 * The log is useful after a renderer crash, so a destroyed sender must not
 * suppress it; only the UI delivery is guarded by `isDestroyed()` above.
 */
function logRecognitionProgress(logger, event = {}) {
  if (!logger) return;
  const numericPercent = Number(event.percent);
  const percent = Number.isFinite(numericPercent) ? Math.round(numericPercent) : null;
  const message = [
    percent === null ? null : `${percent}%`,
    event.message || "识别进度",
    event.warning || null,
  ].filter(Boolean).join(" · ");
  const meta = {
    phase: event.phase,
    percent,
    completed: event.completed,
    total: event.total,
    completedViews: event.completedViews,
    totalViews: event.totalViews,
    viewIndex: event.viewIndex,
    pageNumber: event.pageNumber,
    cacheHit: event.cacheHit,
  };
  const level = event.warning ? "warn" : "info";
  logger[level]("recognition", message, meta);
}
