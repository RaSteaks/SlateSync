import { Braces, CheckCircle2, KeyRound, Monitor, Moon, Save, Sun, Terminal, Wrench } from "lucide-react";
import { useEffect, useState } from "react";
import type { ConfigData, JsonSchemaCapabilityResult, OcrCheckResult, OcrEngineStatus, OcrSelection, OcrSettings, VisionOcrCheckResult } from "../../../shared/contracts/index.js";
import { Badge, Button, Field, Icon, InlineError, Input, Select, Stack, StatusIndicator, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useSettingsStore, useUiStore, type Theme } from "../../state";
import styles from "../../app/app.module.css";

const KEY_PROVIDERS = new Set(["openai", "openrouter", "token-plan", "dashscope"]);

type StatusTone = "neutral" | "success" | "warning" | "danger";

function engineStatus(config: ConfigData | null, id: "vision" | "paddleocr"): OcrEngineStatus | null {
  return config?.ocrEngines.find((engine) => engine.id === id) || null;
}

function engineStatusLabel(engine: OcrEngineStatus | null): string {
  if (!engine) return "未读取";
  if (engine.enabled && engine.available) return "环境可用";
  if (engine.enabled) return "已启用但不可用";
  return engine.mode === "auto" ? "未启用" : "已关闭";
}

function engineStatusTone(engine: OcrEngineStatus | null): StatusTone {
  if (!engine) return "neutral";
  if (engine.enabled && engine.available) return "success";
  if (engine.enabled && engine.required) return "danger";
  if (engine.enabled) return "warning";
  return "neutral";
}

function selectionTone(selection: OcrSelection | undefined): StatusTone {
  if (!selection?.id) return "neutral";
  if (selection.enabled && selection.available) return "success";
  return selection.required ? "danger" : "warning";
}

function selectionModeLabel(mode: string): string {
  if (mode === "required") return "必需模式";
  if (mode === "explicit") return "显式指定";
  if (mode === "fallback") return "自动回退";
  if (mode === "auto") return "自动选择";
  return "未启用";
}

function engineModeLabel(mode: string): string {
  if (mode === "auto") return "自动";
  if (["1", "true", "yes", "on"].includes(mode)) return "开启";
  if (["0", "false", "no", "off"].includes(mode)) return "关闭";
  return mode || "默认";
}

function selectionLabel(selection: OcrSelection | undefined): string {
  if (!selection) return "正在读取 OCR 能力";
  if (selection.id === "vision") return "Apple Vision OCR";
  if (selection.id === "paddleocr") return "PaddleOCR";
  return "未启用本地 OCR";
}

function selectionStatusLabel(selection: OcrSelection | undefined): string {
  if (!selection?.id) return "将降级为页面图片识别";
  if (selection.enabled && selection.available) return "已选中且可运行";
  if (selection.required) return "必需引擎当前不可用";
  return "已选中但当前不可用";
}

interface OcrStatusPanelProps {
  config: ConfigData | null;
  ocr: OcrSettings | null;
  pythonPath: string;
  setPythonPath: (value: string) => void;
  paddleCheck: OcrCheckResult | null;
  ocrState: "idle" | "checking" | "saving" | "saved";
  checkAndSaveOcr: (event: React.FormEvent<HTMLFormElement>) => void;
  visionCheck: VisionOcrCheckResult | null;
  visionCheckState: "idle" | "checking" | "checked";
  checkVision: () => Promise<void>;
}

function OcrStatusPanel({
  config,
  ocr,
  pythonPath,
  setPythonPath,
  paddleCheck,
  ocrState,
  checkAndSaveOcr,
  visionCheck,
  visionCheckState,
  checkVision,
}: OcrStatusPanelProps) {
  const selection = config?.ocrSelection;
  const vision = engineStatus(config, "vision");
  const paddle = engineStatus(config, "paddleocr");
  const visionSelected = selection?.id === "vision";
  const paddleSelected = selection?.id === "paddleocr";

  return <Surface className={`${styles.panel} ${styles.ocrPanel}`} aria-labelledby="local-ocr-title">
    <div className={styles.sectionHeader}>
      <div>
        <p className={styles.kicker}>执行路由</p>
        <h2 className={styles.sectionTitle} id="local-ocr-title">本地 OCR</h2>
      </div>
      <Terminal size={19} aria-hidden="true" />
    </div>
    <Text tone="muted" size="sm">下面的状态来自 Main 进程；“检查”会运行实际的 Vision bridge 或 PaddleOCR Python 检查脚本。</Text>

    <div className={styles.ocrDecision} aria-live="polite">
      <div>
        <Text tone="subtle" size="xs" mono>下一次识别将使用</Text>
        <Text as="p" size="lg" weight="bold" className={styles.ocrDecisionTitle}>{selectionLabel(selection)}</Text>
        <Text tone="muted" size="sm">{selection?.id ? selection.label : selection?.reason || "正在从 Main 进程读取 OCR 选择。"}</Text>
      </div>
      <div className={styles.ocrDecisionMeta}>
        <StatusIndicator tone={selectionTone(selection)} label={selectionStatusLabel(selection)} />
        <Text tone="subtle" size="xs">选择方式：{selection ? selectionModeLabel(selection.mode) : "等待能力状态"}</Text>
      </div>
    </div>

    <div className={styles.ocrEngineGrid}>
      <article className={styles.ocrEngineCard} data-selected={visionSelected ? "true" : undefined} aria-labelledby="vision-ocr-title">
        <div className={styles.ocrEngineHeader}>
          <div>
            <Text as="h3" id="vision-ocr-title" size="md" weight="bold">Apple Vision OCR</Text>
            <Text tone="muted" size="sm">macOS Vision Framework，本机提取文字与坐标，不需要 Python。</Text>
          </div>
          <StatusIndicator tone={engineStatusTone(vision)} label={engineStatusLabel(vision)} />
        </div>
        {visionSelected && <Badge tone="accent">当前优先</Badge>}
        <dl className={styles.ocrEngineDetails}>
          <div><dt>运行模式</dt><dd>{engineModeLabel(vision?.mode || "")}</dd></div>
          <div><dt>能力来源</dt><dd>{vision?.available ? "已发现 Vision bridge 或 Swift 工具链" : "未发现 bridge 或 swiftc"}</dd></div>
          <div><dt>识别配置</dt><dd>{vision ? `${vision.recognitionLevel === "fast" ? "快速" : "高精度"} · ${vision.language || "自动语言"}` : "—"}</dd></div>
        </dl>
        {visionCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
          <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 检查通过 · {visionCheck.engine} {visionCheck.modelVersion}</Text>
          <Text tone="subtle" size="xs">macOS {visionCheck.systemVersion}</Text>
        </div>}
        {visionCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
          <Text tone="danger" size="sm">检查失败 · {visionCheck.error.message}</Text>
        </div>}
        <Stack direction="row" justify="between" align="center" wrap>
          <Text tone="subtle" size="xs">{visionCheckState === "idle" ? "尚未执行运行检查" : visionCheckState === "checking" ? "正在启动 Vision bridge…" : visionCheck?.ok ? "最近检查通过" : "最近检查失败"}</Text>
          <Button size="sm" variant="secondary" loading={visionCheckState === "checking"} onClick={() => void checkVision()} startIcon={<Wrench size={15} />}>检查 Vision OCR</Button>
        </Stack>
      </article>

      <article className={styles.ocrEngineCard} data-selected={paddleSelected ? "true" : undefined} aria-labelledby="paddle-ocr-title">
        <div className={styles.ocrEngineHeader}>
          <div>
            <Text as="h3" id="paddle-ocr-title" size="md" weight="bold">PaddleOCR</Text>
            <Text tone="muted" size="sm">Python + PaddleOCR，本地可选引擎。</Text>
          </div>
          <StatusIndicator tone={engineStatusTone(paddle)} label={engineStatusLabel(paddle)} />
        </div>
        {paddleSelected && <Badge tone="accent">当前优先</Badge>}
        <dl className={styles.ocrEngineDetails}>
          <div><dt>运行模式</dt><dd>{engineModeLabel(paddle?.mode || "")}</dd></div>
          <div><dt>能力来源</dt><dd>{paddle?.available ? "已发现 Python 环境与 PaddleOCR" : "未发现可用 Python 环境"}</dd></div>
          <div><dt>模型配置</dt><dd>{paddle ? `${paddle.modelVersion || "PP-OCRv5"} · ${paddle.profileLabel || paddle.profile || "平衡"}` : "—"}</dd></div>
        </dl>
        <form noValidate onSubmit={checkAndSaveOcr} className={styles.ocrPaddleForm}>
          <Field label="PaddleOCR Python 环境路径" hint="例如 .venv-paddleocr/bin/python；Vision OCR 不需要填写此项。">
            <Input value={pythonPath} onChange={(event) => setPythonPath(event.target.value)} placeholder="python3 或绝对路径" />
          </Field>
          <Stack direction="row" justify="between" align="center" wrap>
            <Text tone="subtle" size="xs">{ocr?.setupCompleted ? "当前环境已完成设置" : "尚未验证"}</Text>
            <Button type="submit" size="sm" loading={ocrState === "checking" || ocrState === "saving"} startIcon={<Wrench size={15} />}>验证并保存</Button>
          </Stack>
          {paddleCheck?.ok === true && <div className={styles.ocrCheckResult} data-tone="success" role="status">
            <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> 检查通过 · Paddle {paddleCheck.paddleVersion} / PaddleOCR {paddleCheck.paddleOcrVersion}</Text>
          </div>}
          {paddleCheck?.ok === false && <div className={styles.ocrCheckResult} data-tone="danger" role="alert">
            <Text tone="danger" size="sm">检查失败 · {paddleCheck.error.message}</Text>
          </div>}
        </form>
      </article>
    </div>

    <Text tone="subtle" size="xs" className={styles.ocrFootnote}>选择顺序由 Main 进程统一决定：必需模式 → 显式开启 → 自动模式；自动模式在 macOS 上优先 Vision OCR。OCR 只提供文字证据，最终结果仍由视觉模型结合页面图片确认。</Text>
  </Surface>;
}

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
  const [providerId, setProviderId] = useState(config?.providers[0]?.id || "");
  const [apiKey, setApiKey] = useState("");
  const [pythonPath, setPythonPath] = useState("");
  const [ocrError, setOcrError] = useState<string | null>(null);
  const [paddleCheck, setPaddleCheck] = useState<OcrCheckResult | null>(null);
  const [visionCheck, setVisionCheck] = useState<VisionOcrCheckResult | null>(null);
  const [visionCheckState, setVisionCheckState] = useState<"idle" | "checking" | "checked">("idle");
  const [keyState, setKeyState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [ocrState, setOcrState] = useState<"idle" | "checking" | "saving" | "saved">("idle");
  const [jsonSchemaState, setJsonSchemaState] = useState<"idle" | "checking">("idle");
  const [jsonSchemaResult, setJsonSchemaResult] = useState<JsonSchemaCapabilityResult | null>(null);
  const [jsonSchemaError, setJsonSchemaError] = useState<string | null>(null);

  useEffect(() => {
    setProviderId((previous) => config?.providers.some((provider) => provider.id === previous) ? previous : config?.providers[0]?.id || "");
  }, [config]);
  useEffect(() => {
    setJsonSchemaResult(null);
    setJsonSchemaError(null);
  }, [providerId]);
  useEffect(() => {
    let active = true;
    void (async () => {
      try {
        const settings = await unwrap(await getSlateSync().settings.getOcrSettings());
        if (active) { setOcr(settings); setPythonPath(settings.pythonPath || ""); }
      } catch (error) {
        if (active) setOcrError(appErrorFromUnknown(error).message);
      }
    })();
    return () => { active = false; };
  }, [setOcr]);

  const provider = config?.providers.find((item) => item.id === providerId);
  const saveKey = async () => {
    if (!provider || !KEY_PROVIDERS.has(provider.id)) return;
    setKeyState("saving");
    try {
      await unwrap(await getSlateSync().settings.saveProviderKey({ provider: provider.id, apiKey: apiKey.trim() }));
      setApiKey("");
      setConfig(await unwrap(await getSlateSync().app.getConfig()));
      setKeyState("saved");
      setToast({ tone: "success", message: "Provider 配置已保存；密钥不会回显" });
    } catch (error) { setKeyState("error"); setOcrError(appErrorFromUnknown(error).message); }
  };

  const checkAndSaveOcr = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setOcrError(null);
    setPaddleCheck(null);
    setOcrState("checking");
    try {
      const check = await unwrap(await getSlateSync().settings.checkOcr({ pythonPath: pythonPath.trim() }));
      setPaddleCheck(check);
      if (!check.ok) throw new Error(check.error.message);
      setOcrState("saving");
      const saved = await unwrap(await getSlateSync().settings.saveOcrSettings({ pythonPath: pythonPath.trim() }));
      setOcr(saved);
      setConfig(await unwrap(await getSlateSync().app.getConfig()));
      setOcrState("saved");
      setToast({ tone: "success", message: "OCR 环境已验证并保存" });
    } catch (error) { setOcrState("idle"); setOcrError(appErrorFromUnknown(error).message); }
  };

  const checkVision = async () => {
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
  };

  // Keep the probe in Main so API keys and local endpoint details never enter
  // the Renderer request payload or the persisted project settings.
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

  return <div className={styles.page}>
    <div className={styles.pageHeader}><div><p className={styles.eyebrow}>设备设置</p><h1 className={styles.heading}>全局设置</h1><p className={styles.subtitle}>密钥、OCR 与外观。</p></div></div>
    <div className={`${styles.grid} ${styles.gridTwo}`}>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>Provider</p><h2 className={styles.sectionTitle}>访问密钥</h2></div><KeyRound size={19} aria-hidden="true" /></div><Text tone="muted" size="sm">密钥保存在当前设备，保存后不会回显。</Text><div className={styles.grid} style={{ marginTop: 18 }}><Field label="Provider"><Select value={providerId} onChange={(event) => setProviderId(event.target.value)}>{config?.providers.map((item) => <option key={item.id} value={item.id}>{item.label}{item.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field><Field label="新 API Key" hint={provider && !KEY_PROVIDERS.has(provider.id) ? "此 Provider 通过环境变量配置。" : "留空并保存可清除覆盖值。"}><Input type="password" value={apiKey} onChange={(event) => setApiKey(event.target.value)} autoComplete="new-password" spellCheck={false} disabled={!provider || !KEY_PROVIDERS.has(provider.id)} placeholder="粘贴 API Key" /></Field><Stack direction="row" justify="between" align="center"><Text tone={keyState === "error" ? "danger" : "subtle"} size="xs">{keyState === "saved" ? "已保存" : provider?.requiredEnv?.join(" / ") || ""}</Text><Button onClick={() => void saveKey()} loading={keyState === "saving"} startIcon={<Save size={15} />}>保存密钥</Button></Stack></div></Surface>
      {provider?.id === "openai-compatible" && <Surface className={styles.panel} tone="accent"><div className={styles.sectionHeader}><div><p className={styles.kicker}>接口能力</p><h2 className={styles.sectionTitle}>JSON Schema 检测</h2></div><Braces size={19} aria-hidden="true" /></div><Text tone="muted" size="sm">发送一个不含图片的最小请求，验证当前兼容接口和模型是否支持严格 JSON Schema。</Text><Stack direction="row" justify="between" align="center" style={{ marginTop: 18 }}><Text tone={jsonSchemaResult?.supported ? "success" : "subtle"} size="xs">{jsonSchemaResult ? `${jsonSchemaResult.transport} · HTTP ${jsonSchemaResult.status || "未知"}` : "尚未检测"}</Text><Button onClick={() => void checkCompatibleJsonSchema()} loading={jsonSchemaState === "checking"} disabled={!provider.configured} startIcon={<Braces size={15} />}>测试 JSON Schema</Button></Stack>{jsonSchemaResult && <Text tone={jsonSchemaResult.supported ? "success" : "warning"} size="sm" style={{ marginTop: 12 }}><Icon icon={jsonSchemaResult.supported ? CheckCircle2 : Braces} size={15} /> {jsonSchemaResult.message}</Text>}{jsonSchemaError && <div style={{ marginTop: 12 }}><InlineError message={jsonSchemaError} /></div>}</Surface>}
      <OcrStatusPanel config={config} ocr={ocr} pythonPath={pythonPath} setPythonPath={setPythonPath} paddleCheck={paddleCheck} ocrState={ocrState} checkAndSaveOcr={checkAndSaveOcr} visionCheck={visionCheck} visionCheckState={visionCheckState} checkVision={checkVision} />
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>外观</p><h2 className={styles.sectionTitle}>工作台外观</h2></div>{theme === "system" ? <Monitor size={18} /> : theme === "dark" ? <Moon size={18} /> : <Sun size={18} />}</div><div className={styles.grid} style={{ marginTop: 14 }}><Field label="主题" hint={theme === "system" ? "自动跟随 macOS 的浅色/深色外观。" : "侧栏主题图标与此设置保持同步。"}><Select value={theme} onChange={(event) => setTheme(event.target.value as Theme)}><option value="system">自动 · 跟随系统</option><option value="dark">深色 · Graphite</option><option value="light">浅色 · Paper</option></Select></Field><Field label="信息密度"><Select value={density} onChange={(event) => setDensity(event.target.value as "comfortable" | "compact")}><option value="comfortable">标准</option><option value="compact">紧凑 · 大表格</option></Select></Field></div></Surface>
    </div>
    {ocrError && <div style={{ marginTop: 16 }}><InlineError message={ocrError} /></div>}
  </div>;
}
