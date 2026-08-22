import { CheckCircle2, KeyRound, Moon, Save, Sun, Terminal, Wrench } from "lucide-react";
import { useEffect, useState } from "react";
import { Button, Field, Icon, InlineError, Input, Select, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useSettingsStore, useUiStore } from "../../state";
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

  useEffect(() => {
    setProviderId((previous) => config?.providers.some((provider) => provider.id === previous) ? previous : config?.providers[0]?.id || "");
  }, [config]);
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

  return <div className={styles.page}>
    <div className={styles.pageHeader}><div><p className={styles.eyebrow}>SYSTEM SETTINGS / MACHINE</p><h1 className={styles.heading}>全局设置</h1><p className={styles.subtitle}>Provider 密钥、OCR 环境与外观偏好只属于当前设备，不会写入项目数据库。</p></div></div>
    <div className={`${styles.grid} ${styles.gridTwo}`}>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>PROVIDER ACCESS</p><h2 className={styles.sectionTitle}>Provider 密钥</h2></div><KeyRound size={19} aria-hidden="true" /></div><Text tone="muted" size="sm">只保存“已配置”状态与本机受保护密钥。界面不会读取或展示已保存内容。</Text><div className={styles.grid} style={{ marginTop: 18 }}><Field label="Provider"><Select value={providerId} onChange={(event) => setProviderId(event.target.value)}>{config?.providers.map((item) => <option key={item.id} value={item.id}>{item.label}{item.configured ? " · 已配置" : " · 未配置"}</option>)}</Select></Field><Field label="新 API Key" hint={provider && !KEY_PROVIDERS.has(provider.id) ? "此 Provider 需要通过环境变量配置。" : "留空并保存可清除当前设备上的覆盖值。"}><Input type="password" value={apiKey} onChange={(event) => setApiKey(event.target.value)} autoComplete="new-password" spellCheck={false} disabled={!provider || !KEY_PROVIDERS.has(provider.id)} placeholder="粘贴新的 API Key" /></Field><Stack direction="row" justify="between" align="center"><Text tone={keyState === "error" ? "danger" : "subtle"} size="xs">{keyState === "saved" ? "已保存" : provider?.requiredEnv?.join(" / ") || ""}</Text><Button onClick={() => void saveKey()} loading={keyState === "saving"} startIcon={<Save size={15} />}>保存密钥</Button></Stack></div></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>OCR RUNTIME</p><h2 className={styles.sectionTitle}>本地 OCR</h2></div><Terminal size={19} aria-hidden="true" /></div><Text tone="muted" size="sm">验证完成前不会写入路径；识别仍可在不启用 OCR 时使用多模态流程。</Text><form onSubmit={checkAndSaveOcr} className={styles.grid} style={{ marginTop: 18 }}><Field label="Python 环境路径" hint="例如 .venv-paddleocr/bin/python"><Input value={pythonPath} onChange={(event) => setPythonPath(event.target.value)} placeholder="python3 或绝对路径" /></Field><Stack direction="row" justify="between" align="center"><Text tone="subtle" size="xs">{ocr?.setupCompleted ? "当前环境已完成设置" : "尚未验证"}</Text><Button type="submit" loading={ocrState === "checking" || ocrState === "saving"} startIcon={<Wrench size={15} />}>验证并保存</Button></Stack>{ocrState === "saved" && <Text tone="success" size="sm"><Icon icon={CheckCircle2} size={15} /> OCR 可用，设置已保存。</Text>}</form></Surface>
      <Surface className={styles.panel}><div className={styles.sectionHeader}><div><p className={styles.kicker}>APPEARANCE</p><h2 className={styles.sectionTitle}>工作台外观</h2></div>{theme === "dark" ? <Moon size={18} /> : <Sun size={18} />}</div><div className={styles.grid} style={{ marginTop: 14 }}><Field label="主题"><Select value={theme} onChange={(event) => setTheme(event.target.value as "dark" | "light")}><option value="dark">深色 · Graphite</option><option value="light">浅色 · Paper</option></Select></Field><Field label="信息密度"><Select value={density} onChange={(event) => setDensity(event.target.value as "comfortable" | "compact")}><option value="comfortable">标准</option><option value="compact">紧凑 · 大表格</option></Select></Field></div></Surface>
    </div>
    {ocrError && <div style={{ marginTop: 16 }}><InlineError message={ocrError} /></div>}
  </div>;
}
