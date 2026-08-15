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
  createDiagnosticsStore,
  createSessionCapture,
} from "../lib/diagnostics.mjs";
import { createTaskStore } from "../lib/task-store.mjs";
import { checkPaddleOcr } from "../lib/ocr/paddleocr.mjs";

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
    diagnostics,
    taskStore,
    scenarioStore,
    settingsStore,
    runtimeSettings,
    checkOcr = checkPaddleOcr,
  } = context;

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
      scenarios: scenarioStore ? await scenarioStore.listProfiles() : [],
    };
  });

  ipcMain.handle("list-scenarios", async () =>
    scenarioStore ? scenarioStore.listProfiles() : [],
  );

  ipcMain.handle("load-scenario", async (_event, { id }) => {
    if (!scenarioStore) throw new Error("场记结构存储不可用");
    return scenarioStore.getProfile(id);
  });

  ipcMain.handle("import-scenario", async (_event, { profile }) => {
    if (!scenarioStore) throw new Error("场记结构存储不可用");
    return scenarioStore.importProfile(profile);
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
    const capture = createSessionCapture();
    try {
      const input = recognitionInput(body, await getWorkflowConfig());
      const result = await recognizeSlate(input, {
        env: runtimeEnv(),
        ocrAutoEnable: true,
        scenarioStore,
        onProgress: (progressEvent) => {
          if (!event.sender.isDestroyed()) {
            event.sender.send("recognition-progress", progressEvent);
          }
        },
        capture,
      });
      const sessionId = diagnostics
        ? await diagnostics.saveSession(capture.session)
        : null;
      const taskId = taskStore
        ? await taskStore.saveTask({
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
            usage: result.usage,
            durationMs: result.durationMs,
            ocrSummary: result.ocr,
            diagnosticSessionId: sessionId,
          })
        : null;
      return {
        ...clientRecognitionResult(result),
        diagnosticSessionId: sessionId,
        taskId,
      };
    } catch (error) {
      capture.setError(error);
      if (diagnostics) {
        await diagnostics.saveSession(capture.session).catch(() => {});
      }
      throw error;
    } finally {
      release();
    }
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

  ipcMain.handle("list-tasks", async () => {
    if (!taskStore) return { tasks: [] };
    return taskStore.listTasks();
  });

  ipcMain.handle("load-task", async (_event, { id }) => {
    if (!taskStore) throw new Error("任务存储不可用");
    return taskStore.loadTask(id);
  });

  ipcMain.handle("save-task", async (_event, task) => {
    if (!taskStore) throw new Error("任务存储不可用");
    if (task?.id) {
      return taskStore.updateTask(task.id, task);
    }
    return taskStore.saveTask(task);
  });

  ipcMain.handle("delete-task", async (_event, { id }) => {
    if (!taskStore) throw new Error("任务存储不可用");
    await taskStore.deleteTask(id);
    return { deleted: id };
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
}

function recognitionInput(body, workflowConfig) {
  return {
    providerId: body.provider,
    modelId: body.model,
    imageDataUrl: body.imageDataUrl,
    imageDataUrls: body.imageDataUrls,
    imageDataGroups: body.imageDataGroups,
    pdfDataUrl: body.pdfDataUrl,
    pageCount: body.pageCount,
    filename: body.filename,
    accuracyMode: body.accuracyMode,
    scenarioId: body.scenarioId,
    customPrompt: body.customPrompt,
    slateCsvRecords: body.slateCsvRecords || null,
    fieldFormats: workflowConfig.resolve.fieldFormats,
    comments: workflowConfig.resolve.comments,
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
