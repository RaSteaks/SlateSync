import { CheckCircle2, Eye, EyeOff, Pencil, Plus, RefreshCw, Search, ShieldCheck, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ConfigData, CustomProviderConfigRequest, CustomProviderSummary, ModelData, ModelDiscoveryResult, UpdateCustomProviderRequest } from "../../../shared/contracts/index.js";
import { Badge, Button, Checkbox, Dialog, Field, InlineError, Input, Select, Stack, StatusIndicator, Surface, Text, Textarea } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useProjectStore, useUiStore } from "../../state";
import styles from "../../app/app.module.css";

type ProviderDraft = CustomProviderConfigRequest & { apiKey: string };

const EMPTY_DRAFT: ProviderDraft = {
  name: "",
  baseUrl: "",
  transport: "chat-completions",
  jsonMode: "json_schema",
  imageDetail: "high",
  manualModelIds: [],
  apiKey: "",
};

/** Machine-level custom endpoint CRUD and two-stage model capability checks. */
export function CustomProviderSettingsPanel() {
  const config = useProjectStore((state) => state.config) as ConfigData | null;
  const setConfig = useProjectStore((state) => state.setConfig);
  const setToast = useUiStore((state) => state.setToast);
  const [providers, setProviders] = useState<CustomProviderSummary[]>([]);
  const [selectedId, setSelectedId] = useState("");
  const [dialog, setDialog] = useState<"new" | "edit" | "discard" | null>(null);
  const [discardTarget, setDiscardTarget] = useState<"new" | "edit">("new");
  const [draft, setDraft] = useState<ProviderDraft>(EMPTY_DRAFT);
  const [draftDirty, setDraftDirty] = useState(false);
  const [showKey, setShowKey] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [discovery, setDiscovery] = useState<ModelDiscoveryResult | null>(null);
  const [search, setSearch] = useState("");
  const [selectedPending, setSelectedPending] = useState<string[]>([]);
  const [probeBusy, setProbeBusy] = useState(false);
  const [probeProgress, setProbeProgress] = useState<{ completed: number; total: number; model?: string } | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<CustomProviderSummary | null>(null);
  const discoveryRequestRef = useRef(0);
  const probeRequestRef = useRef(0);
  const probeActiveRef = useRef(false);
  const selectedIdRef = useRef(selectedId);
  selectedIdRef.current = selectedId;

  const loadProviders = async () => {
    try {
      const api = getSlateSync();
      if (typeof api.settings.listCustomProviders !== "function") return;
      const next = await unwrap(await api.settings.listCustomProviders());
      setProviders(next);
      setSelectedId((previous) => next.some((item) => item.id === previous) ? previous : next[0]?.id || "");
    } catch (cause) {
      setError(appErrorFromUnknown(cause).message);
    }
  };

  useEffect(() => { void loadProviders(); }, []);

  useEffect(() => {
    let api;
    try { api = getSlateSync(); } catch { return undefined; }
    if (typeof api.settings.onModelProbeProgress !== "function") return undefined;
    return api.settings.onModelProbeProgress((event) => {
      if (!probeActiveRef.current) return;
      if (event.providerId !== selectedId) return;
      const currentRevision = providers.find((provider) => provider.id === selectedId)?.revision;
      if (event.revision != null && currentRevision != null && event.revision !== currentRevision) return;
      setProbeProgress({ completed: event.completed, total: event.total, model: event.model });
    });
  }, [providers, selectedId]);

  const selected = providers.find((provider) => provider.id === selectedId) || null;
  const filteredModels = useMemo(() => {
    const normalized = search.trim().toLocaleLowerCase();
    const all = discovery?.models || [];
    return normalized ? all.filter((model) => `${model.label} ${model.id} ${model.vendor || ""}`.toLocaleLowerCase().includes(normalized)) : all;
  }, [discovery, search]);
  const groupedModels = useMemo(() => {
    const groups = new Map<string, ModelData[]>();
    for (const model of filteredModels) {
      const vendor = model.vendor || model.id.split("/", 1)[0] || "other";
      groups.set(vendor, [...(groups.get(vendor) || []), model]);
    }
    return [...groups.entries()];
  }, [filteredModels]);
  const pendingModels = discovery?.pendingModels || [];
  const failedModels = discovery?.failedModels || [];
  const unsupportedModels = discovery?.unsupportedModels || [];
  const pendingVendorGroups = useMemo(() => {
    const groups = new Map<string, ModelData[]>();
    for (const model of pendingModels) {
      const vendor = model.vendor || model.id.split("/", 1)[0] || "other";
      groups.set(vendor, [...(groups.get(vendor) || []), model]);
    }
    return [...groups.entries()];
  }, [pendingModels]);

  const refreshConfig = async () => {
    try { setConfig(await unwrap(await getSlateSync().app.getConfig())); } catch { /* settings mutation already succeeded */ }
  };

  const invalidateAsyncState = () => {
    // A selection/edit/delete invalidates both discovery and probe UI tokens;
    // late IPC responses must not repaint a different provider's panel.
    discoveryRequestRef.current += 1;
    probeRequestRef.current += 1;
    probeActiveRef.current = false;
    setDiscovery(null);
    setSelectedPending([]);
    setProbeBusy(false);
    setProbeProgress(null);
  };

  const openNew = () => {
    setDraft({ ...EMPTY_DRAFT, manualModelIds: [] });
    setDraftDirty(false);
    setShowKey(false);
    setError(null);
    setDialog("new");
  };

  const openEdit = () => {
    if (!selected) return;
    setDraft({
      id: selected.id,
      name: selected.name,
      baseUrl: selected.baseUrl,
      transport: selected.transport,
      jsonMode: selected.jsonMode,
      imageDetail: selected.imageDetail,
      manualModelIds: [...selected.manualModelIds],
      apiKey: "",
    });
    setDraftDirty(false);
    setShowKey(false);
    setError(null);
    setDialog("edit");
  };

  const closeDialog = () => {
    if (busy) return;
    if (draftDirty) { setDiscardTarget(dialog === "edit" ? "edit" : "new"); setDialog("discard"); return; }
    setDialog(null);
  };

  const saveDraft = async () => {
    setBusy(true);
    setError(null);
    try {
      const api = getSlateSync();
      const request: ProviderDraft = {
        ...draft,
        manualModelIds: String((draft.manualModelIds || []).join("\n")).split(/[\n,]/).map((id) => id.trim()).filter(Boolean),
      };
      // The Main handler requires an existing ID for edits; never trust a
      // renderer draft's optional field to target an arbitrary provider.
      const updateRequest: UpdateCustomProviderRequest = {
        ...request,
        id: selected?.id || request.id || "",
      };
      if (dialog === "edit" && !updateRequest.id) throw new Error("请选择要编辑的接口");
      const saved = dialog === "edit"
        ? await unwrap(await api.settings.updateCustomProvider(updateRequest))
        : await unwrap(await api.settings.createCustomProvider(request));
      setProviders((previous) => dialog === "edit" ? previous.map((item) => item.id === saved.id ? saved : item) : [...previous, saved]);
      setSelectedId(saved.id);
      setDialog(null);
      setDraftDirty(false);
      // A connection/manual-model edit increments Main's revision and
      // invalidates the prior discovery. Clear the local projection too so an
      // old model list cannot look selectable while the user decides to scan
      // or probe the new configuration.
      invalidateAsyncState();
      setSearch("");
      setToast({ tone: "success", message: dialog === "edit" ? "自定义接口已更新" : "自定义接口已添加" });
      await refreshConfig();
    } catch (cause) {
      setError(appErrorFromUnknown(cause).message);
    } finally { setBusy(false); }
  };

  const deleteProvider = async () => {
    if (!deleteTarget) return;
    invalidateAsyncState();
    setBusy(true);
    setError(null);
    try {
      await unwrap(await getSlateSync().settings.deleteCustomProvider({ id: deleteTarget.id, confirm: true }));
      setProviders((previous) => previous.filter((item) => item.id !== deleteTarget.id));
      setSelectedId((previous) => previous === deleteTarget.id ? "" : previous);
      setDeleteTarget(null);
      setToast({ tone: "success", message: "接口已删除；项目中的旧引用已保留并需要重新选择" });
      await refreshConfig();
    } catch (cause) { setError(appErrorFromUnknown(cause).message); }
    finally { setBusy(false); }
  };

  const discover = async (forceRefresh = false) => {
    const providerId = selectedId;
    if (!providerId || selectedIdRef.current !== providerId) return;
    const requestId = ++discoveryRequestRef.current;
    setError(null);
    try {
      const result = await unwrap(await getSlateSync().recognition.getModels({ providerId, forceRefresh }));
      if (requestId !== discoveryRequestRef.current || selectedIdRef.current !== providerId) return;
      setDiscovery(result);
      // Canceled probes remain visible as pending, but an interrupted request
      // must not be selected again until the user explicitly checks it.
      setSelectedPending((result.pendingModels || [])
        .filter((model) => model.capabilityStatus !== "canceled")
        .map((model) => model.apiId || model.id));
    } catch (cause) {
      if (requestId === discoveryRequestRef.current && selectedIdRef.current === providerId) {
        setError(appErrorFromUnknown(cause).message);
      }
    }
  };

  const probeModels = async (modelIds: readonly string[]) => {
    const providerId = selectedId;
    if (!providerId || selectedIdRef.current !== providerId || !modelIds.length) return;
    const requestId = ++probeRequestRef.current;
    probeActiveRef.current = true;
    setProbeBusy(true);
    setProbeProgress({ completed: 0, total: modelIds.length });
    setError(null);
    try {
      await unwrap(await getSlateSync().settings.probeCustomModels({ providerId, modelIds }));
      if (!probeActiveRef.current || requestId !== probeRequestRef.current || selectedIdRef.current !== providerId) return;
      await discover(true);
      await loadProviders();
    } catch (cause) {
      if (requestId === probeRequestRef.current && selectedIdRef.current === providerId) {
        setError(appErrorFromUnknown(cause).message);
      }
    } finally {
      if (requestId === probeRequestRef.current) {
        probeActiveRef.current = false;
        setProbeBusy(false);
        setProbeProgress(null);
      }
    }
  };

  const probe = () => probeModels(selectedPending);
  const retryModel = (modelId: string) => probeModels([modelId]);

  const togglePendingVendor = (vendor: string, checked: boolean) => {
    const ids = pendingModels
      .filter((model) => (model.vendor || model.id.split("/", 1)[0] || "other") === vendor)
      .map((model) => model.apiId || model.id);
    setSelectedPending((previous) => {
      const next = new Set(previous);
      ids.forEach((id) => checked ? next.add(id) : next.delete(id));
      return [...next];
    });
  };

  const cancelProbe = async () => {
    if (!selectedId) return;
    try { await unwrap(await getSlateSync().settings.cancelCustomModelProbe({ providerId: selectedId })); }
    catch (cause) { setError(appErrorFromUnknown(cause).message); }
  };

  useEffect(() => {
    invalidateAsyncState();
    setSearch("");
    if (selectedId) void discover();
  }, [selectedId]);

  const updateDraft = <K extends keyof ProviderDraft>(key: K, value: ProviderDraft[K]) => {
    setDraft((previous) => ({
      ...previous,
      [key]: value,
      // Typing a replacement after pressing the separate "clear" action
      // must switch back to replacement semantics; otherwise Main would see
      // both flags and correctly prioritize the clear request.
      ...(key === "apiKey"
        ? String(value || "").trim()
          ? { clearApiKey: false, replaceApiKey: true }
          : { replaceApiKey: false }
        : {}),
    }));
    setDraftDirty(true);
  };

  return <Surface className={`${styles.panel} ${styles.runtimeSettingsPanel}`} data-testid="custom-provider-settings">
    <div className={styles.sectionHeader}><div><p className={styles.kicker}>连接注册表</p><h2 className={styles.sectionTitle}>自定义模型接口</h2></div><ShieldCheck size={19} aria-hidden="true" /></div>
    <Text tone="muted" size="sm">支持任意 OpenAI 兼容 Chat Completions 或 Responses 接口。API Key 可留空；HTTP 地址仅建议用于本机或可信 LAN。</Text>
    {error && <InlineError message={error} />}
    <div className={`${styles.grid} ${styles.customProviderLayout}`} style={{ marginTop: 16 }}>
      <Surface compact>
        <Stack direction="row" justify="between" align="center"><Text weight="bold">已注册接口</Text><Button size="sm" onClick={openNew} startIcon={<Plus size={14} />}>新增</Button></Stack>
        <Stack gap={1} style={{ marginTop: 12 }}>
          {providers.length ? providers.map((provider) => <button type="button" key={provider.id} onClick={() => setSelectedId(provider.id)} style={{ textAlign: "left", border: 0, borderRadius: 10, padding: "10px 12px", background: provider.id === selectedId ? "var(--ss-color-surface-accent)" : "transparent", color: "inherit", cursor: "pointer" }}>
            <Stack direction="row" justify="between" align="center"><Text weight="bold" size="sm">{provider.name}</Text><StatusIndicator tone={provider.keyConfigured ? "success" : "neutral"} label={provider.keyConfigured ? "已鉴权" : "无鉴权"} /></Stack>
            <Text tone="subtle" size="xs" mono>{provider.baseUrl}</Text>
          </button>) : <Text tone="subtle" size="sm">还没有自定义接口</Text>}
        </Stack>
      </Surface>
      <Surface compact>
        {!selected ? <Text tone="muted">选择左侧接口，或新增一个 OpenAI 兼容连接。</Text> : <>
          <Stack direction="row" justify="between" align="center" wrap><div><Text as="h3" size="lg" weight="bold">{selected.name}</Text><Text tone="subtle" size="xs" mono>{selected.baseUrl}</Text></div><Stack direction="row" gap={2} wrap><Button size="sm" variant="secondary" onClick={openEdit} startIcon={<Pencil size={14} />}>编辑</Button><Button size="sm" variant="danger" onClick={() => setDeleteTarget(selected)} startIcon={<Trash2 size={14} />}>删除</Button></Stack></Stack>
          {!selected.baseUrl.startsWith("https:") && <Text tone="warning" size="xs" style={{ marginTop: 8 }}>当前使用非 HTTPS 地址，传输内容可能被同网段监听。</Text>}
          {discovery?.warning && <Text tone="warning" size="xs" style={{ marginTop: 8 }}>{discovery.warning}</Text>}
          <Stack direction="row" gap={2} wrap style={{ marginTop: 14 }}><Button size="sm" onClick={() => void discover(true)} startIcon={<RefreshCw size={14} />}>检测模型列表</Button><Button size="sm" variant="secondary" onClick={() => void probe()} disabled={!selectedPending.length || probeBusy} loading={probeBusy} startIcon={<CheckCircle2 size={14} />}>验证所选待定模型</Button>{probeBusy && <Button size="sm" variant="ghost" onClick={() => void cancelProbe()}>取消</Button>}</Stack>
          {probeProgress && <Text tone="subtle" size="xs" style={{ marginTop: 8 }}>探针进度：{probeProgress.completed}/{probeProgress.total}{probeProgress.model ? ` · ${probeProgress.model}` : ""}</Text>}
          <div style={{ marginTop: 16 }}><Stack direction="row" justify="between" align="center"><Text weight="bold">可用于识别 · {discovery?.models.length || 0}</Text><div className={styles.secretInputRow}><Search size={14} aria-hidden="true" /><Input aria-label="搜索模型" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索名称或 ID" />{search && <Button size="sm" variant="ghost" aria-label="清除搜索" onClick={() => setSearch("")}><X size={14} /></Button>}</div></Stack>
            <Stack gap={1} style={{ marginTop: 8 }}>{groupedModels.map(([vendor, vendorModels]) => <details key={vendor} open style={{ borderBottom: "1px solid var(--ss-color-line)", paddingBottom: 4 }}><summary style={{ cursor: "pointer", padding: "6px 4px", color: "var(--ss-color-ink-muted)", fontSize: "0.78rem" }}>{vendorLabel(vendor)} · {vendorModels.length} 个</summary><Stack gap={1}>{vendorModels.map((model) => <div key={model.id} style={{ padding: "8px 10px", borderTop: "1px solid var(--ss-color-line)" }}><Stack direction="row" justify="between" align="center"><Text size="sm" weight="bold">{model.label}</Text><Badge tone="success">{model.capabilityStatus === "verified" ? "探针通过" : model.capabilityStatus === "inferred" ? "族谱推断" : "API 声明"}</Badge></Stack><Text tone="subtle" size="xs" mono>{model.id}</Text><Text tone="muted" size="xs">{model.description} · {model.qualityLabel || "精度暂无数据"} · {model.valueLabel || "价格未知"}</Text>{(model.qualitySource || model.qualityUpdatedAt || model.valueSource || model.valueUpdatedAt) && <Text tone="subtle" size="xs">依据：{model.qualitySource || "精度暂无数据"}{model.qualityUpdatedAt ? `（${model.qualityUpdatedAt}）` : ""}{model.valueSource ? `；${model.valueSource}` : ""}{model.valueUpdatedAt ? `（${model.valueUpdatedAt}）` : ""}</Text>}</div>)}</Stack></details>)}</Stack>
          </div>
          <div style={{ marginTop: 16 }}><Stack direction="row" justify="between" align="center"><Text weight="bold">待验证 · {pendingModels.length}</Text>{pendingModels.length > 0 && <Text tone="subtle" size="xs">按供应商选择</Text>}</Stack><Stack gap={2} style={{ marginTop: 8 }}>{pendingVendorGroups.map(([vendor, vendorModels]) => { const ids = vendorModels.map((model) => model.apiId || model.id); const allSelected = ids.every((id) => selectedPending.includes(id)); return <Surface compact key={vendor}><Stack direction="row" justify="between" align="center"><Text size="sm" weight="bold">{vendorLabel(vendor)} · {vendorModels.length} 个</Text><Button type="button" size="sm" variant="ghost" onClick={() => togglePendingVendor(vendor, !allSelected)}>{allSelected ? "取消全选" : "全选"}</Button></Stack><Stack gap={1} style={{ marginTop: 6 }}>{vendorModels.map((model) => { const id = model.apiId || model.id; return <Checkbox key={id} label={`${model.label} · ${id}`} checked={selectedPending.includes(id)} onChange={(event) => setSelectedPending((previous) => event.target.checked ? [...new Set([...previous, id])] : previous.filter((value) => value !== id))} />; })}</Stack></Surface>; })}</Stack></div>
          {(failedModels.length > 0 || unsupportedModels.length > 0) && <div style={{ marginTop: 16 }}><Text weight="bold">不支持或失败 · {failedModels.length + unsupportedModels.length}</Text><Stack gap={1} style={{ marginTop: 8 }}>{failedModels.map((model) => { const id = model.apiId || model.id; return <Stack direction="row" justify="between" align="center" key={`failed-${id}`}><Text tone="muted" size="sm">探针失败：{model.label} · {id}{model.capabilityMessage ? ` · ${model.capabilityMessage}` : ""}</Text><Button type="button" size="sm" variant="ghost" disabled={probeBusy} onClick={() => void retryModel(id)}>重试</Button></Stack>; })}{unsupportedModels.map((item) => <Text key={`unsupported-${item.id}`} tone="subtle" size="xs">{item.id} · {item.reason}</Text>)}</Stack></div>}
        </>}
      </Surface>
    </div>
    {dialog && <Dialog open title={dialog === "discard" ? "放弃未保存更改？" : dialog === "new" ? "新增自定义接口" : "编辑自定义接口"} description={dialog === "discard" ? "当前表单仍有未保存内容。" : "连接信息保存到本机全局配置；密钥不会进入普通配置文件。"} onClose={() => { if (dialog === "discard") setDialog(discardTarget); else closeDialog(); }} size="wide" footer={dialog === "discard" ? <Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={() => setDialog(discardTarget)}>继续编辑</Button><Button variant="danger" onClick={() => { setDialog(null); setDraftDirty(false); }}>放弃更改</Button></Stack> : <Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={closeDialog} disabled={busy}>取消</Button><Button onClick={() => void saveDraft()} loading={busy}>保存接口</Button></Stack>}>
      {dialog === "discard" ? <Text tone="warning">关闭对话框不会自动保存。选择“继续编辑”返回当前表单。</Text> : <div className={styles.formGrid}>
        <Field label="接口名称" hint="1–60 字符，忽略大小写后不能重复。"><Input autoFocus value={draft.name} onChange={(event) => updateDraft("name", event.target.value)} /></Field>
        <Field label="Base URL" hint="http(s)，不能包含账号、查询参数或片段。"><Input value={draft.baseUrl} onChange={(event) => updateDraft("baseUrl", event.target.value)} spellCheck={false} /></Field>
        <Field label="请求协议"><Select value={draft.transport} onChange={(event) => updateDraft("transport", event.target.value as ProviderDraft["transport"])}><option value="chat-completions">Chat Completions</option><option value="responses">Responses</option></Select></Field>
        <Field label="JSON 模式"><Select value={draft.jsonMode} onChange={(event) => updateDraft("jsonMode", event.target.value as ProviderDraft["jsonMode"])}><option value="json_schema">JSON Schema</option><option value="json_object">JSON Object</option><option value="prompt">Prompt 约束</option></Select></Field>
        <Field label="图片细节"><Select value={draft.imageDetail} onChange={(event) => updateDraft("imageDetail", event.target.value as ProviderDraft["imageDetail"])}><option value="auto">自动</option><option value="low">低</option><option value="high">高</option><option value="original">原始</option></Select></Field>
        <Field label="API Key" hint={dialog === "edit" ? "留空保留现有 Key；清除使用下方独立动作。" : "留空表示无鉴权接口。"}><div className={styles.secretInputRow}><Input type={showKey ? "text" : "password"} value={draft.apiKey} onChange={(event) => updateDraft("apiKey", event.target.value)} autoComplete="new-password" spellCheck={false} /><Button type="button" size="sm" variant="ghost" onClick={() => setShowKey((previous) => !previous)}>{showKey ? <EyeOff size={14} /> : <Eye size={14} />}</Button></div></Field>
        <Field label="手动模型 ID" hint="每行一个；无法读取 /models 时会进入待验证。"><Textarea className="resize-none" value={(draft.manualModelIds || []).join("\n")} onChange={(event) => updateDraft("manualModelIds", event.target.value.split(/[\n,]/).map((id) => id.trim()).filter(Boolean))} placeholder="vendor/vision-model" spellCheck={false} rows={3} /></Field>
        {dialog === "edit" && <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}><Text tone="subtle" size="xs">修改 Base URL、协议、JSON 模式、模型 ID 或 Key 会让旧探针结果失效。</Text><Button type="button" size="sm" variant="ghost" onClick={() => { updateDraft("apiKey", ""); updateDraft("clearApiKey", true); updateDraft("replaceApiKey", true); }}>清除现有 Key</Button></Stack>}
      </div>}
    </Dialog>}
    {deleteTarget && <Dialog open title="删除自定义接口？" description="项目数据库不会被批量修改；引用该接口的项目会显示需要重新选择。" onClose={() => setDeleteTarget(null)} footer={<Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={() => setDeleteTarget(null)} disabled={busy}>取消</Button><Button variant="danger" onClick={() => void deleteProvider()} loading={busy}>确认删除</Button></Stack>}><Text tone="warning">将删除「{deleteTarget.name}」的配置、密钥和能力缓存。</Text></Dialog>}
  </Surface>;
}

function vendorLabel(vendor: string): string {
  const labels: Record<string, string> = { anthropic: "Anthropic", deepseek: "DeepSeek", google: "Google", meta: "Meta", minimax: "MiniMax", mistralai: "Mistral AI", openai: "OpenAI", qwen: "Qwen", xai: "xAI", other: "其他" };
  return labels[vendor.toLowerCase()] || vendor.split(/[-_]/).filter(Boolean).map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ") || "其他";
}
