// Registers every ipcMain.handle channel that the renderer's preload bridge
// (electron/preload.cjs) invokes. Each handler adapts a main-process service —
// recognition, model discovery, key/settings/task/diagnostic stores, file
// dialogs, slate directory scanning — into a JSON-safe IPC response, stripping
// pricing/cost fields before returning them to the client.
import { recognizeSlate } from "../lib/ai-client.mjs";
import { PROVIDERS, publicConfig } from "../lib/config.mjs";
import {
  discoverVisionModels,
  staticProviderModels,
} from "../lib/model-discovery.mjs";
import {
  createSessionCapture,
} from "../lib/diagnostics.mjs";
import { checkPaddleOcr } from "../lib/ocr/paddleocr.mjs";
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
    runtimeProviderKeys,
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
    libraryActions,
    checkOcr = checkPaddleOcr,
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
  let activeLibraryWrites = 0;
  let libraryTransferInProgress = false;

  ipcMain.handle("get-config", async () => {
    const config = publicConfig(runtimeEnv(), await getWorkflowConfig(), {
      ocrAutoEnable: true,
    });
    return {
      ...config,
      upload: {
        ...config.upload,
        maxRequestBytes: settings.maxBodyBytes,
      },
    };
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
    const provider = PROVIDERS[providerId];
    if (!provider) {
      throw new Error("未知 API 服务商");
    }
    if (providerId === "openai-compatible") {
      throw new Error("OpenAI 兼容 API 需通过环境变量配置");
    }
    const apiKey = String(body?.apiKey || "").trim();
    if (apiKey) {
      runtimeProviderKeys.set(providerId, apiKey);
    } else {
      runtimeProviderKeys.delete(providerId);
    }
    if (keyStore) {
      await keyStore.save(runtimeProviderKeys);
    }
    return {
      provider: providerId,
      configured: Boolean(
        runtimeProviderKeys.get(providerId) || process.env[provider.envKey],
      ),
    };
  });

  ipcMain.handle("get-models", async (_event, { providerId, forceRefresh }) => {
    try {
      const result = await discoverVisionModels(providerId, {
        forceRefresh: Boolean(forceRefresh),
        env: runtimeEnv(),
      });
      return clientModelDiscovery(result);
    } catch (error) {
      if (Number(error.status) === 400) throw error;
      const fallback = staticProviderModels(providerId);
      return {
        provider: providerId,
        source: "static-fallback",
        refreshedAt: new Date().toISOString(),
        availableModelCount: null,
        visionModelCount: fallback.length,
        fixedModelCount: fallback.length,
        warning: error.message || "无法读取实时模型列表",
        models: fallback.map(withoutPricing),
      };
    }
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
      const result = await recognize(input, {
        env: runtimeEnv(),
        ocrAutoEnable: true,
        projectScopedOutput: Boolean(projectContext.project),
        scenarioStore: projectContext.scenarioStore,
        onProgress: (progressEvent) => {
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
      capture.setError(error);
      if (activeProjectId && projectContext?.diagnostics) {
        await projectContext.diagnostics.saveSession(capture.session).catch(() => {});
      }
      throw error;
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

  ipcMain.handle("get-ocr-settings", async () => ({
    pythonPath: runtimeSettings?.ocrPythonPath || "",
    setupCompleted: Boolean(runtimeSettings?.ocrSetupCompleted),
    setupSkipped: Boolean(runtimeSettings?.ocrSetupSkipped),
  }));

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
      const checkResult = await checkOcr({ pythonPath });
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
    return {
      pythonPath: runtimeSettings.ocrPythonPath,
      setupCompleted: runtimeSettings.ocrSetupCompleted,
      setupSkipped: runtimeSettings.ocrSetupSkipped,
    };
  });

  ipcMain.handle("check-ocr", async (_event, body) =>
    checkOcr({ pythonPath: String(body?.pythonPath ?? "").trim() }),
  );

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

function clientModelDiscovery(result) {
  return {
    ...result,
    models: (result.models || []).map(withoutPricing),
  };
}

function withoutPricing(model) {
  const publicModel = { ...model };
  delete publicModel.price;
  delete publicModel.prices;
  delete publicModel.pricePerMillion;
  delete publicModel.priceUpdatedAt;
  return publicModel;
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
