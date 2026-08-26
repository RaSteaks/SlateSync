import { Braces, CheckCircle2, KeyRound, Monitor, Moon, Save, Sun, Terminal, Wrench } from "lucide-react";
import { useEffect, useState } from "react";
import type { JsonSchemaCapabilityResult } from "../../../shared/contracts/index.js";
import { Button, Field, Icon, InlineError, Input, Select, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useSettingsStore, useUiStore, type Theme } from "../../state";
import styles from "../../app/app.module.css";

const KEY_PROVIDERS = new Set(["openai", "openrouter", "token-plan", "dashscope"]);

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
    setOcrState("checking");
    try {
      const check = await unwrap(await getSlateSync().settings.checkOcr({ pythonPath: pythonPath.trim() }));
      if (!check.ok) throw new Error(check.error.message);
      setOcrState("saving");
      const saved = await unwrap(await getSlateSync().settings.saveOcrSettings({ pythonPath: pythonPath.trim() }));
      setOcr(saved);
      setOcrState("saved");
      setToast({ tone: "success", message: "OCR 环境已验证并保存" });
    } catch (error) { setOcrState("idle"); setOcrError(appErrorFromUnknown(error).message); }
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
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>本地能力</p><h2 className={styles.sectionTitle}>本地 OCR</h2></div><Terminal size={19} aria-hidden="true" /></div><Text tone="muted" size="sm">验证成功后才会保存路径。</Text><form noValidate onSubmit={checkAndSaveOcr} className={styles.grid} style={{ marginTop: 18 }}><Field label="Python 环境路径" hint="例如 .venv-paddleocr/bin/python"><Input value={pythonPath} onChange={(event) => setPythonPath(event.target.value)} placeholder="python3 或绝对路径" /></Field><Stack direction="row" justify="between" align="center"><Text tone="subtle" size="xs">{ocr?.setupCompleted ? "当前环境已完成设置" : "尚未验证"}</Text><Button type="submit" loading={ocrState === "checking" || ocrState === "saving"} startIcon={<Wrench size={15} />}>验证并保存</Button></Stack>{ocrState === "saved" && <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> OCR 可用，设置已保存。</Text>}</form></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>外观</p><h2 className={styles.sectionTitle}>工作台外观</h2></div>{theme === "system" ? <Monitor size={18} /> : theme === "dark" ? <Moon size={18} /> : <Sun size={18} />}</div><div className={styles.grid} style={{ marginTop: 14 }}><Field label="主题"><Select value={theme} onChange={(event) => setTheme(event.target.value as Theme)}><option value="system">跟随系统</option><option value="dark">深色 · Graphite</option><option value="light">浅色 · Paper</option></Select></Field><Field label="信息密度"><Select value={density} onChange={(event) => setDensity(event.target.value as "comfortable" | "compact")}><option value="comfortable">标准</option><option value="compact">紧凑 · 大表格</option></Select></Field></div></Surface>
    </div>
    {ocrError && <div style={{ marginTop: 16 }}><InlineError message={ocrError} /></div>}
  </div>;
}
