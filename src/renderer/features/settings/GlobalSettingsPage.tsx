import { Braces, CheckCircle2, Eye, EyeOff, Gauge, KeyRound, Monitor, RotateCcw, Save } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import type { GlobalSettingKey, JsonSchemaCapabilityResult, OcrCheckResult, VisionOcrCheckResult, PaddleOcrInstallProgress } from "../../../shared/contracts/index.js";
import { Badge, Button, Dialog, Field, Icon, InlineError, Input, SegmentedControl, Select, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, requireGlobalSettingsApi, unwrap } from "../../services/api";
import { GLOBAL_SETTINGS_SAVE_EVENT } from "../../services/keyboard-shortcuts";
import { useGlobalSettingsStore, useProjectStore, useSettingsStore, useUiStore, type Density, type Theme } from "../../state";
import styles from "../../app/app.module.css";
import { CustomProviderSettingsPanel } from "./CustomProviderSettingsPanel";
import { OcrEnvironmentDialog } from "./OcrEnvironmentDialog";
import { OcrStatusPanel } from "./OcrStatusPanel";
import { GlobalSettingsSectionNav } from "./GlobalSettingsSectionNav";
import { NumericSettingField, SelectSettingField, TextSettingField } from "./NumericSettingField";
import { saveGlobalSettingsChanges, isGlobalSettingsDirty } from "./globalSettingsActions";
import { ocrPreferenceFromValues } from "./globalSettingsModel";
import type { PaddleOcrInstallState } from "./ocrEngineStatus";

const KEY_PROVIDERS = new Set(["openai", "openrouter", "tokenplan", "dashscope", "openai-compatible"]);
const PROVIDER_BASE_URL_KEYS: Partial<Record<string, GlobalSettingKey>> = {
  openai: "OPENAI_BASE_URL",
  openrouter: "OPENROUTER_BASE_URL",
  tokenplan: "TOKENPLAN_BASE_URL",
  dashscope: "DASHSCOPE_BASE_URL",
  "openai-compatible": "OPENAI_COMPATIBLE_BASE_URL",
};

// Appearance applies immediately through the UI store and never joins the
// saved-settings dirty model, so it uses segments instead of a save field.
const THEME_SEGMENTS: ReadonlyArray<{ value: Theme; label: string }> = [
  { value: "system", label: "自动" },
  { value: "dark", label: "深色" },
  { value: "light", label: "浅色" },
];
const DENSITY_SEGMENTS: ReadonlyArray<{ value: Density; label: string }> = [
  { value: "comfortable", label: "标准" },
  { value: "compact", label: "紧凑" },
];

export function GlobalSettingsPage() {
  const config = useProjectStore((state) => state.config);
  const setConfig = useProjectStore((state) => state.setConfig);
  const ocr = useSettingsStore((state) => state.ocr);
  const setOcr = useSettingsStore((state) => state.setOcr);
  const theme = useUiStore((state) => state.theme);
  const density = useUiStore((state) => state.density);
  const setTheme = useUiStore((state) => state.setTheme);
  const setDensity = useUiStore((state) => state.setDensity);
  const setToast = useUiStore((state) => state.setToast);
  // Primitive subscriptions only: typing in any draft field re-renders that
  // field's subtree, never the page shell.
  const saved = useGlobalSettingsStore((state) => state.saved);
  const dirtyCount = useGlobalSettingsStore((state) => state.dirtyKeys.size);
  const saveState = useGlobalSettingsStore((state) => state.saveState);
  const saveError = useGlobalSettingsStore((state) => state.saveError);
  const hasFieldErrors = useGlobalSettingsStore((state) => Object.keys(state.fieldErrors).length > 0);

  const [providerId, setProviderId] = useState(config?.providers[0]?.id || "");
  const [apiKey, setApiKey] = useState("");
  const [showApiKey, setShowApiKey] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [paddleCheck, setPaddleCheck] = useState<OcrCheckResult | null>(null);
  const [visionCheck, setVisionCheck] = useState<VisionOcrCheckResult | null>(null);
  const [visionCheckState, setVisionCheckState] = useState<"idle" | "checking" | "checked">("idle");
  const [keyState, setKeyState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [ocrState, setOcrState] = useState<"idle" | "checking" | "saving" | "saved">("idle");
  const [paddleInstallState, setPaddleInstallState] = useState<PaddleOcrInstallState>("idle");
  const [paddleInstallProgress, setPaddleInstallProgress] = useState<PaddleOcrInstallProgress | null>(null);
  const [paddleInstallError, setPaddleInstallError] = useState<string | null>(null);
  const [jsonSchemaState, setJsonSchemaState] = useState<"idle" | "checking">("idle");
  const [jsonSchemaResult, setJsonSchemaResult] = useState<JsonSchemaCapabilityResult | null>(null);
  const [jsonSchemaError, setJsonSchemaError] = useState<string | null>(null);
  const [ocrDialogOpen, setOcrDialogOpen] = useState(false);
  const [resetDialogOpen, setResetDialogOpen] = useState(false);
  const autoOpenedOcrDialogRef = useRef(false);

  useEffect(() => {
    setProviderId((previous) => {
      const builtins = config?.providers.filter((provider) => !provider.id.startsWith("openai-compatible:")) || [];
      return builtins.some((provider) => provider.id === previous) ? previous : builtins[0]?.id || "";
    });
  }, [config]);

  useEffect(() => {
    setJsonSchemaResult(null);
    setJsonSchemaError(null);
  }, [providerId]);

  // First-run guidance: when the capability snapshot says no local OCR engine
  // can run yet, surface the detection/download dialog once per visit so the
  // user learns what is missing without hunting for the header button. A
  // deliberate "disabled" preference means the user opted out of local OCR
  // entirely and must not be nagged.
  useEffect(() => {
    if (autoOpenedOcrDialogRef.current || !saved) return;
    const engines = config?.ocrEngines;
    if (!engines?.length) return;
    const draft = useGlobalSettingsStore.getState();
    if (ocrPreferenceFromValues({ ...saved.values, ...draft.draftValues }) === "disabled") return;
    if (engines.some((engine) => engine.available)) return;
    autoOpenedOcrDialogRef.current = true;
    setOcrDialogOpen(true);
  }, [config, saved]);

  // The draft store outlives this page, so re-fetching on every mount would
  // wipe an in-progress edit session after a route detour. External .env edits
  // only become visible after a save/reset (new snapshot) or an app reload.
  useEffect(() => {
    if (useGlobalSettingsStore.getState().saved) return undefined;
    let active = true;
    void (async () => {
      try {
        const api = requireGlobalSettingsApi();
        const [savedGlobalSettings, savedOcrSettings] = await Promise.all([
          unwrap(await api.settings.getGlobalSettings()),
          unwrap(await api.settings.getOcrSettings()),
        ]);
        if (!active) return;
        useGlobalSettingsStore.getState().adoptServerSnapshot(savedGlobalSettings);
        setOcr(savedOcrSettings);
      } catch (error) {
        if (active) setActionError(appErrorFromUnknown(error).message);
      }
    })();
    return () => { active = false; };
  }, [setOcr]);

  useEffect(() => {
    let active = true;
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.onPaddleOcrInstallProgress !== "function") return undefined;
      const unsubscribe = api.settings.onPaddleOcrInstallProgress((progress) => {
        if (!active) return;
        setPaddleInstallState("installing");
        setPaddleInstallError(null);
        setPaddleInstallProgress(progress);
      });
      return () => {
        active = false;
        unsubscribe();
      };
    } catch {
      // The settings page remains usable when HMR leaves an older Preload in
      // the window; the install action will show its own recovery error.
      return () => { active = false; };
    }
  }, []);

  // Cmd+S (dispatched by the shell) shares the single save entry point.
  useEffect(() => {
    const onSaveShortcut = () => { void saveGlobalSettingsChanges(); };
    window.addEventListener(GLOBAL_SETTINGS_SAVE_EVENT, onSaveShortcut);
    return () => window.removeEventListener(GLOBAL_SETTINGS_SAVE_EVENT, onSaveShortcut);
  }, []);

  // Closing the window with unsaved settings drafts asks for confirmation.
  useEffect(() => {
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!isGlobalSettingsDirty()) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    return () => window.removeEventListener("beforeunload", onBeforeUnload);
  }, []);

  const provider = config?.providers.find((item) => item.id === providerId);
  const providerBaseUrlKey = provider ? PROVIDER_BASE_URL_KEYS[provider.id] : undefined;
  const providerKeyConfigured = provider ? (saved?.keyConfigured[provider.id] ?? provider.configured) : false;

  // Switching providers must not carry a typed key into the wrong credential
  // slot, so the key input and its visibility reset with the selection.
  const handleProviderChange = (nextProviderId: string) => {
    setProviderId(nextProviderId);
    setApiKey("");
    setShowApiKey(false);
  };

  const saveKey = async () => {
    if (!provider || !KEY_PROVIDERS.has(provider.id)) return;
    setKeyState("saving");
    setActionError(null);
    try {
      const api = getSlateSync();
      const savedKey = await unwrap(await api.settings.saveProviderKey({ provider: provider.id, apiKey: apiKey.trim() }));
      setApiKey("");
      setShowApiKey(false);
      setConfig(await unwrap(await api.app.getConfig()));
      // Keep unsaved endpoint/OCR edits in the draft store while updating only
      // the provider readiness flag returned by the key-save operation.
      useGlobalSettingsStore.getState().setKeyConfigured(provider.id, savedKey.configured);
      setKeyState("saved");
      setToast({ tone: "success", message: "Provider 配置已保存；密钥不会回显" });
    } catch (error) {
      setKeyState("error");
      setActionError(appErrorFromUnknown(error).message);
    }
  };

  // The capability probe stays in Main so endpoint details, API keys and
  // project images never enter a Renderer request body.
  const checkCompatibleJsonSchema = async () => {
    setJsonSchemaState("checking");
    setJsonSchemaError(null);
    try {
      setJsonSchemaResult(await unwrap(await getSlateSync().settings.checkCompatibleJsonSchema()));
    } catch (error) {
      setJsonSchemaResult(null);
      setJsonSchemaError(appErrorFromUnknown(error).message);
    } finally {
      setJsonSchemaState("idle");
    }
  };

  const checkAndSaveOcr = useCallback(async () => {
    setActionError(null);
    setPaddleCheck(null);
    setOcrState("checking");
    try {
      const api = getSlateSync();
      const store = useGlobalSettingsStore.getState();
      const pythonPath = (store.draftValues.PADDLEOCR_PYTHON ?? store.saved?.values.PADDLEOCR_PYTHON ?? "").trim();
      const check = await unwrap(await api.settings.checkOcr({ pythonPath }));
      setPaddleCheck(check);
      if (!check.ok) throw new Error(check.error.message);
      setOcrState("saving");
      const savedOcr = await unwrap(await api.settings.saveOcrSettings({ pythonPath }));
      setOcr(savedOcr);
      // The verified path was persisted by its own endpoint; fold it into the
      // snapshot and clear any draft of the same key.
      useGlobalSettingsStore.getState().mergeSaved({ PADDLEOCR_PYTHON: savedOcr.pythonPath }, ["PADDLEOCR_PYTHON"]);
      setConfig(await unwrap(await api.app.getConfig()));
      setOcrState("saved");
      setToast({ tone: "success", message: "OCR 环境已验证并保存" });
    } catch (error) {
      setOcrState("idle");
      setActionError(appErrorFromUnknown(error).message);
    }
  }, [setConfig, setOcr, setToast]);

  const checkVision = useCallback(async () => {
    setVisionCheck(null);
    setVisionCheckState("checking");
    try {
      const result = await unwrap(await getSlateSync().settings.checkVisionOcr());
      setVisionCheck(result);
      setVisionCheckState("checked");
      if (result.ok) setToast({ tone: "success", message: "Apple Vision OCR 检查通过" });
    } catch (error) {
      const appError = appErrorFromUnknown(error);
      setVisionCheck({ ok: false, error: { code: appError.code, message: appError.message } });
      setVisionCheckState("checked");
    }
  }, [setToast]);

  const installPaddleOcr = useCallback(async () => {
    if (paddleInstallState === "installing") return;
    setPaddleInstallState("installing");
    setPaddleInstallProgress({ stage: "detect-python", percent: 0, message: "正在准备 PaddleOCR 安装…" });
    setPaddleInstallError(null);
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.installPaddleOcr !== "function") {
        throw new Error("当前 Renderer 与 Preload 版本不一致，无法安装 PaddleOCR。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
      }
      const installed = await unwrap(await api.settings.installPaddleOcr());
      setOcr(installed);
      // A one-click install intentionally owns this path: leaving an old
      // manual path dirty would make the successful installation unreachable.
      useGlobalSettingsStore.getState().mergeSaved({ PADDLEOCR_PYTHON: installed.pythonPath }, ["PADDLEOCR_PYTHON"]);
      setConfig(await unwrap(await api.app.getConfig()));
      setPaddleInstallProgress({ stage: "completed", percent: 100, message: "PaddleOCR 已安装并验证通过。" });
      setPaddleInstallState("installed");
      setToast({ tone: "success", message: "PaddleOCR 已安装并验证通过" });
    } catch (error) {
      const appError = appErrorFromUnknown(error);
      setPaddleInstallError(appError.message);
      setPaddleInstallState(appError.code === "PADDLEOCR_INSTALL_CANCELED" ? "canceled" : "error");
    }
  }, [paddleInstallState, setConfig, setOcr, setToast]);

  const cancelPaddleOcrInstall = useCallback(async () => {
    if (paddleInstallState !== "installing") return;
    try {
      const api = requireGlobalSettingsApi();
      if (typeof api.settings?.cancelPaddleOcrInstall !== "function") {
        throw new Error("当前 Renderer 与 Preload 版本不一致，无法取消 PaddleOCR 安装。请完全退出 SlateSync 后重新启动；不要只刷新窗口。");
      }
      await unwrap(await api.settings.cancelPaddleOcrInstall());
    } catch (error) {
      setPaddleInstallError(appErrorFromUnknown(error).message);
      setPaddleInstallState("error");
    }
  }, [paddleInstallState]);

  const confirmReset = async () => {
    const ok = await saveGlobalSettingsChanges(true);
    if (ok) setResetDialogOpen(false);
  };

  // The header owns the single save/discard actions; sections below only edit
  // the draft store. Independent endpoints (provider keys, OCR environment)
  // keep their own buttons because they persist through separate APIs.
  return <div className={`${styles.page} ${styles.settingsPage}`}>
    <div className={styles.pageHeader}>
      <div>
        <p className={styles.eyebrow}>设备设置</p>
        <h1 className={styles.heading}>全局设置</h1>
      </div>
      <div className={styles.pageActions}>
        {dirtyCount > 0 && <Badge tone="warning" data-testid="settings-dirty-chip">{dirtyCount} 项未保存</Badge>}
        <Button
          data-testid="global-settings-save"
          loading={saveState === "saving"}
          disabled={hasFieldErrors}
          onClick={() => void saveGlobalSettingsChanges()}
          startIcon={<Save size={15} />}
        >{dirtyCount > 0 ? `保存修改（${dirtyCount} 项未保存）` : "保存全局配置"}</Button>
        <Button variant="ghost" data-testid="global-settings-discard" disabled={dirtyCount === 0 || saveState === "saving"} onClick={() => useGlobalSettingsStore.getState().discardDraft()}>放弃更改</Button>
        <Button variant="ghost" disabled={saveState === "saving"} onClick={() => setResetDialogOpen(true)} startIcon={<RotateCcw size={15} />}>恢复环境默认</Button>
      </div>
    </div>

    {saveError && <InlineError message={saveError} />}
    {actionError && <InlineError message={actionError} />}

    <div className={styles.helpLayout}>
      <GlobalSettingsSectionNav />
      <div className={styles.helpContent}>
        <Surface as="section" id="settings-general" className={styles.helpSection} aria-label="密钥与外观">
          <div className={styles.settingsOverviewGrid} data-testid="settings-overview-grid">
            <Surface className={styles.panel}>
              <div className={styles.sectionHeader}><div><p className={styles.kicker}>Provider</p><h2 className={styles.sectionTitle}>访问密钥与接口</h2></div><KeyRound size={19} aria-hidden="true" /></div>
              <Text tone="muted" size="sm">密钥保存在独立的本机凭据文件，保存后不会回显；Base URL 等普通参数写入全局配置。</Text>
              <div className={styles.formGrid} style={{ marginTop: 18 }}>
                <Field label="Provider"><Select value={providerId} onChange={(event) => handleProviderChange(event.target.value)}>{config?.providers.filter((item) => !item.id.startsWith("openai-compatible:")).map((item) => <option key={item.id} value={item.id}>{item.label}{item.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field>
                <Field label="API Key" hint={providerKeyConfigured ? "已保存密钥；输入新值可替换，留空并保存可清除应用覆盖。" : "密钥只在 Main 进程中使用，不会显示在页面或项目数据里。"}>
                  <div className={styles.secretInputRow}>
                    <Input type={showApiKey ? "text" : "password"} value={apiKey} onChange={(event) => setApiKey(event.target.value)} autoComplete="new-password" spellCheck={false} disabled={!provider || !KEY_PROVIDERS.has(provider.id)} placeholder={providerKeyConfigured ? "已配置 · 输入新 Key 可替换" : "粘贴 API Key"} />
                    <Button type="button" size="sm" variant="ghost" aria-label={showApiKey ? "隐藏 API Key" : "显示 API Key"} onClick={() => setShowApiKey((visible) => !visible)} disabled={!provider || !KEY_PROVIDERS.has(provider.id)}>{showApiKey ? <EyeOff size={15} aria-hidden="true" /> : <Eye size={15} aria-hidden="true" />}{showApiKey ? "隐藏" : "显示"}</Button>
                  </div>
                </Field>
                {providerBaseUrlKey && <TextSettingField settingKey={providerBaseUrlKey} label="Base URL" hint="只支持 http(s)，不能包含账号、密码、查询参数或片段。" spellCheck={false} />}
                {provider?.id === "openrouter" && <TextSettingField settingKey="OPENROUTER_SITE_URL" label="OpenRouter 应用标识 URL" hint="会作为 HTTP-Referer 发送；可留空。" spellCheck={false} />}
                <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}>
                  <Text tone={keyState === "error" ? "danger" : "subtle"} size="xs">{keyState === "saved" ? "密钥已保存" : provider?.requiredEnv?.join(" / ") || ""}</Text>
                  <Button onClick={() => void saveKey()} loading={keyState === "saving"} startIcon={<Save size={15} />}>保存密钥</Button>
                </Stack>
              </div>
            </Surface>

            <Surface className={styles.panel}>
              <div className={styles.sectionHeader}><div><p className={styles.kicker}>外观</p><h2 className={styles.sectionTitle}>工作台外观</h2></div><Monitor size={18} aria-hidden="true" /></div>
              <Stack direction="column" gap={3} style={{ marginTop: 14 }}>
                <div>
                  <Text tone="subtle" size="xs">主题</Text>
                  <div className={styles.settingsSegmentedRow}>
                    <SegmentedControl label="主题" value={theme} options={THEME_SEGMENTS} onChange={setTheme} />
                  </div>
                </div>
                <div>
                  <Text tone="subtle" size="xs">信息密度</Text>
                  <div className={styles.settingsSegmentedRow}>
                    <SegmentedControl label="信息密度" value={density} options={DENSITY_SEGMENTS} onChange={setDensity} />
                  </div>
                </div>
                <Text tone="subtle" size="xs">外观立即生效，无需保存。</Text>
              </Stack>
            </Surface>
          </div>

          {provider?.id === "openai-compatible" && <Surface className={`${styles.panel} ${styles.runtimeSettingsPanel}`} tone="accent" style={{ marginTop: "var(--ss-layout-gap)" }}>
            <div className={styles.sectionHeader}><div><p className={styles.kicker}>兼容接口</p><h2 className={styles.sectionTitle}>模型与响应格式</h2></div><Braces size={19} aria-hidden="true" /></div>
            <Text tone="muted" size="sm">Key、Base URL 与模型 ID 都需要配置；其他选项决定兼容服务商接受哪一种请求格式。</Text>
            <div className={styles.formGrid} style={{ marginTop: 18 }}>
              <TextSettingField settingKey="OPENAI_COMPATIBLE_MODEL" label="模型 ID" placeholder="your-vision-model" spellCheck={false} />
              <SelectSettingField settingKey="OPENAI_COMPATIBLE_API_MODE" label="请求接口" fallback="chat-completions" options={[{ value: "chat-completions", label: "Chat Completions" }, { value: "responses", label: "Responses" }]} />
              <SelectSettingField settingKey="OPENAI_COMPATIBLE_JSON_MODE" label="JSON 模式" fallback="json_object" options={[{ value: "json_schema", label: "JSON Schema" }, { value: "json_object", label: "JSON Object" }, { value: "prompt", label: "Prompt 约束" }]} />
              <SelectSettingField settingKey="OPENAI_COMPATIBLE_IMAGE_DETAIL" label="图片细节" fallback="high" options={[{ value: "auto", label: "自动" }, { value: "low", label: "低" }, { value: "high", label: "高" }, { value: "original", label: "原始" }]} />
              <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}>
                <Text tone={jsonSchemaResult?.supported ? "success" : "subtle"} size="xs">{jsonSchemaResult ? `${jsonSchemaResult.transport} · HTTP ${jsonSchemaResult.status || "未知"}` : "尚未检测接口能力"}</Text>
                <Button onClick={() => void checkCompatibleJsonSchema()} loading={jsonSchemaState === "checking"} disabled={!provider.configured} startIcon={<Braces size={15} />}>测试 JSON Schema</Button>
              </Stack>
            </div>
            {jsonSchemaResult && <Text tone={jsonSchemaResult.supported ? "success" : "warning"} size="sm" style={{ marginTop: 12 }}><Icon icon={jsonSchemaResult.supported ? CheckCircle2 : Braces} size={15} /> {jsonSchemaResult.message}</Text>}
            {jsonSchemaError && <div style={{ marginTop: 12 }}><InlineError message={jsonSchemaError} /></div>}
          </Surface>}
        </Surface>

        <CustomProviderSettingsPanel />

        <OcrStatusPanel
          config={config}
          ocr={ocr}
          paddleCheck={paddleCheck}
          ocrState={ocrState}
          checkAndSaveOcr={checkAndSaveOcr}
          visionCheck={visionCheck}
          visionCheckState={visionCheckState}
          checkVision={checkVision}
          paddleInstallState={paddleInstallState}
          paddleInstallProgress={paddleInstallProgress}
          paddleInstallError={paddleInstallError}
          installPaddleOcr={installPaddleOcr}
          cancelPaddleOcrInstall={cancelPaddleOcrInstall}
          openEnvironmentDialog={() => setOcrDialogOpen(true)}
        />

        <Surface as="section" id="settings-runtime" className={styles.helpSection} aria-label="运行参数">
          <div className={styles.sectionHeader}><div><p className={styles.kicker}>运行参数</p><h2 className={styles.sectionTitle}>识别与存储</h2></div><Gauge size={19} aria-hidden="true" /></div>
          <Text tone="muted" size="sm">这些参数会即时作用于后续任务；清空某个字段即可回退到 .env 或内置默认值。</Text>
          <div className={styles.formGrid} style={{ marginTop: 18 }}>
            <NumericSettingField settingKey="MAX_BODY_MB" label="请求体上限（MB）" fallback="80" min="20" max="200" step="1" />
            <NumericSettingField settingKey="MODEL_REQUEST_TIMEOUT_MS" label="模型请求超时（毫秒）" hint="30000–3600000。" fallback="180000" min="30000" max="3600000" step="1000" />
            <NumericSettingField settingKey="MODEL_REQUEST_MAX_RETRIES" label="超时重试次数" hint="0–3。" fallback="1" min="0" max="3" step="1" />
            <NumericSettingField settingKey="MODEL_PAGE_CONCURRENCY" label="并行提交页数" hint="1–6。服务商限流时可降为 1。" fallback="2" min="1" max="6" step="1" />
            <NumericSettingField settingKey="MAX_CONCURRENT_RECOGNITIONS" label="并行识别任务数" hint="1–16。调低可减少本机资源占用。" fallback="1" min="1" max="16" step="1" />
            <TextSettingField settingKey="SLATESYNC_CONFIG_PATH" label="工作流配置路径" hint="开发环境读取；修改后下次启动生效。" fallback="slatesync.config.json" spellCheck={false} />
            <TextSettingField settingKey="PADDLE_PDX_CACHE_HOME" label="Paddle 模型缓存路径" hint="留空使用应用默认缓存目录。" placeholder="应用默认" spellCheck={false} />
          </div>
          <div className={styles.settingsSaveRow}>
            <Text tone="subtle" size="xs">已覆盖 {saved?.overrides.length ?? 0} 项非敏感配置</Text>
          </div>
        </Surface>
      </div>
    </div>

    <OcrEnvironmentDialog
      open={ocrDialogOpen}
      onClose={() => setOcrDialogOpen(false)}
      config={config}
      paddleInstallState={paddleInstallState}
      paddleInstallProgress={paddleInstallProgress}
      paddleInstallError={paddleInstallError}
      onInstallPaddleOcr={() => void installPaddleOcr()}
      onCancelPaddleOcrInstall={() => void cancelPaddleOcrInstall()}
      visionCheck={visionCheck}
      visionCheckState={visionCheckState}
      onCheckVision={() => void checkVision()}
    />

    <Dialog
      open={resetDialogOpen}
      title="恢复环境默认？"
      description="已保存的覆盖值会被清除；API Key 与项目数据不受影响。"
      onClose={() => { if (saveState !== "saving") setResetDialogOpen(false); }}
      dismissible={saveState !== "saving"}
      footer={<Stack direction="row" gap={2} justify="end">
        <Button variant="ghost" onClick={() => setResetDialogOpen(false)} disabled={saveState === "saving"}>取消</Button>
        <Button variant="danger" loading={saveState === "saving"} onClick={() => void confirmReset()} startIcon={<RotateCcw size={15} />}>恢复默认</Button>
      </Stack>}
    >
      <Stack direction="column" gap={3}>
        <Text tone="muted" size="sm">所有设置会回到 .env 与内置默认值；本页未保存的修改也会一并丢弃。</Text>
        {saveError && <InlineError message={saveError} />}
      </Stack>
    </Dialog>
  </div>;
}
