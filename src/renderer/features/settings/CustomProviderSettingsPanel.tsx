import { Cable, CheckCircle2, ChevronRight, Eye, EyeOff, Pencil, Plus, RefreshCw, Search, Server, ShieldAlert, ShieldCheck, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { CustomProviderConfigRequest, CustomProviderSummary, ModelData, ModelDiscoveryResult, UpdateCustomProviderRequest } from "../../../shared/contracts/index.js";
import { Badge, Button, Checkbox, Dialog, EmptyState, Field, InlineError, Input, Progress, Select, Spinner, Stack, StatusIndicator, Surface, Text, Textarea } from "../../design-system";
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

type ModelGroup = readonly [string, ModelData[]];
type UnsupportedModel = NonNullable<ModelDiscoveryResult["unsupportedModels"]>[number];

function transportLabel(transport: CustomProviderSummary["transport"]): string {
  return transport === "responses" ? "Responses" : "Chat Completions";
}

function jsonModeLabel(jsonMode: CustomProviderSummary["jsonMode"]): string {
  if (jsonMode === "json_object") return "JSON Object";
  if (jsonMode === "prompt") return "Prompt 约束";
  return "JSON Schema";
}

function imageDetailLabel(imageDetail: CustomProviderSummary["imageDetail"]): string {
  if (imageDetail === "auto") return "图片自动";
  if (imageDetail === "low") return "图片低细节";
  if (imageDetail === "original") return "图片原始";
  return "图片高细节";
}

function modelStatus(model: ModelData): { tone: "accent" | "success"; label: string } {
  if (model.capabilityStatus === "verified") return { tone: "success", label: "探针通过" };
  if (model.capabilityStatus === "inferred") return { tone: "accent", label: "族谱推断" };
  return { tone: "accent", label: "API 声明" };
}

interface ProviderRegistryListProps {
  providers: readonly CustomProviderSummary[];
  selectedId: string;
  loading: boolean;
  onCreate: () => void;
  onSelect: (providerId: string) => void;
}

/** The registry rail owns only selection; editing remains in the detail pane. */
function ProviderRegistryList({ providers, selectedId, loading, onCreate, onSelect }: ProviderRegistryListProps) {
  return <Surface as="section" compact className={styles.providerRegistryPane} aria-labelledby="custom-provider-list-title">
    <div className={styles.providerPaneHeader}>
      <div>
        <Text as="h3" id="custom-provider-list-title" size="md" weight="bold">已注册接口</Text>
        <Text tone="subtle" size="xs" aria-live="polite">{loading ? "正在读取接口" : `${providers.length} 个连接`}</Text>
      </div>
      <Button size="sm" onClick={onCreate} startIcon={<Plus size={14} />}>新增</Button>
    </div>

    {loading ? <div className={styles.providerLoadingState} role="status" aria-label="正在读取自定义接口">
      <Spinner label="正在读取接口" />
      <Text tone="subtle" size="sm">正在读取接口…</Text>
    </div> : providers.length ? <div className={styles.providerList} role="list" aria-label="已注册接口列表">
      {providers.map((provider) => <div role="listitem" key={provider.id}>
        <button
          type="button"
          className={styles.providerListItem}
          data-selected={provider.id === selectedId || undefined}
          aria-pressed={provider.id === selectedId}
          onClick={() => onSelect(provider.id)}
        >
          <span className={styles.providerItemTop}>
            <Text as="span" className={styles.providerItemName} size="sm" weight="bold">{provider.name}</Text>
            <StatusIndicator tone={provider.keyConfigured ? "success" : "neutral"} label={provider.keyConfigured ? "已鉴权" : "无鉴权"} />
          </span>
          <span className={styles.providerItemMeta}>
            <Text as="span" className={styles.providerItemUrl} tone="subtle" size="xs" mono title={provider.baseUrl}>{provider.baseUrl}</Text>
            <span className={styles.providerItemTransport}>{transportLabel(provider.transport)}</span>
            <ChevronRight className={styles.providerItemArrow} size={15} aria-hidden="true" />
          </span>
        </button>
      </div>)}
    </div> : <EmptyState
      icon={Cable}
      title="还没有自定义接口"
      description="新增一个连接后，会在这里显示。"
      className={styles.providerListEmpty}
    />}
  </Surface>;
}

interface ProviderDetailPanelProps {
  selected: CustomProviderSummary | null;
  discovery: ModelDiscoveryResult | null;
  discoveryLoading: boolean;
  groupedModels: readonly ModelGroup[];
  search: string;
  pendingModels: readonly ModelData[];
  pendingVendorGroups: readonly ModelGroup[];
  selectedPending: string[];
  failedModels: readonly ModelData[];
  unsupportedModels: readonly UnsupportedModel[];
  probeBusy: boolean;
  probeProgress: { completed: number; total: number; model?: string } | null;
  onEdit: () => void;
  onDelete: () => void;
  onDiscover: () => void;
  onSearchChange: (value: string) => void;
  onClearSearch: () => void;
  onProbe: () => void;
  onCancelProbe: () => void;
  onTogglePendingVendor: (vendor: string, checked: boolean) => void;
  onTogglePendingModel: (modelId: string, checked: boolean) => void;
  onRetryModel: (modelId: string) => void;
}

/** Details keep status, actions, and capability data in one stable reading order. */
function ProviderDetailPanel({
  selected,
  discovery,
  discoveryLoading,
  groupedModels,
  search,
  pendingModels,
  pendingVendorGroups,
  selectedPending,
  failedModels,
  unsupportedModels,
  probeBusy,
  probeProgress,
  onEdit,
  onDelete,
  onDiscover,
  onSearchChange,
  onClearSearch,
  onProbe,
  onCancelProbe,
  onTogglePendingVendor,
  onTogglePendingModel,
  onRetryModel,
}: ProviderDetailPanelProps) {
  if (!selected) return <Surface as="section" compact className={`${styles.providerDetailPane} ${styles.providerDetailEmptyPane}`} aria-label="接口详情">
    <EmptyState
      icon={Cable}
      title="选择一个接口"
      description="从左侧选择已有连接，或新增一个 OpenAI 兼容连接。"
      className={styles.providerDetailEmpty}
    />
  </Surface>;

  const progressValue = probeProgress && probeProgress.total > 0
    ? (probeProgress.completed / probeProgress.total) * 100
    : 0;

  return <Surface as="section" compact className={styles.providerDetailPane} aria-labelledby="custom-provider-detail-title">
    <div className={styles.providerDetailHeader}>
      <div className={styles.providerIdentity}>
        <span className={styles.providerIdentityIcon}><Server size={18} aria-hidden="true" /></span>
        <div className={styles.providerIdentityCopy}>
          <Text as="h3" id="custom-provider-detail-title" size="lg" weight="bold">{selected.name}</Text>
          <Text as="span" className={styles.providerEndpoint} tone="subtle" size="xs" mono title={selected.baseUrl}>{selected.baseUrl}</Text>
        </div>
      </div>
      <Stack direction="row" gap={2} wrap className={styles.providerDetailActions}>
        <Button size="sm" variant="secondary" onClick={onEdit} startIcon={<Pencil size={14} />}>编辑</Button>
        <Button size="sm" variant="danger" onClick={onDelete} startIcon={<Trash2 size={14} />}>删除</Button>
      </Stack>
    </div>

    <div className={styles.providerActionBar}>
      <div className={styles.providerActionCopy}>
        <Text as="span" tone="muted" size="sm">先检测模型，再验证待定项</Text>
        <Text as="span" tone="subtle" size="xs">验证会使用合成图片，不会发送项目内容。</Text>
      </div>
      <Stack direction="row" gap={2} wrap className={styles.providerActionButtons}>
        <Button size="sm" onClick={onDiscover} loading={discoveryLoading} startIcon={<RefreshCw size={14} />}>检测模型列表</Button>
        <Button size="sm" variant="secondary" onClick={onProbe} disabled={!selectedPending.length || probeBusy} loading={probeBusy} startIcon={<CheckCircle2 size={14} />}>验证所选待定模型</Button>
        {probeBusy && <Button size="sm" variant="ghost" onClick={onCancelProbe}>取消</Button>}
      </Stack>
    </div>

    <div className={styles.providerMetaRow} aria-label="接口能力摘要">
      <StatusIndicator tone={selected.keyConfigured ? "success" : "neutral"} label={selected.keyConfigured ? "已配置 API Key" : "未配置 API Key"} />
      <Badge tone="neutral">{transportLabel(selected.transport)}</Badge>
      <Badge tone="neutral">{jsonModeLabel(selected.jsonMode)}</Badge>
      <Badge tone="neutral">{imageDetailLabel(selected.imageDetail)}</Badge>
    </div>

    {!selected.baseUrl.startsWith("https:") && <div className={styles.providerCallout} data-tone="warning" role="note">
      <ShieldAlert size={16} aria-hidden="true" />
      <Text as="span" tone="warning" size="xs">当前使用非 HTTPS 地址，传输内容可能被同网段监听。</Text>
    </div>}
    {discovery?.warning && <div className={styles.providerCallout} data-tone="warning" role="alert">
      <ShieldAlert size={16} aria-hidden="true" />
      <Text as="span" tone="warning" size="xs">{discovery.warning}</Text>
    </div>}

    {probeProgress && <div className={styles.providerProbeProgress} role="status" aria-live="polite">
      <div className={styles.providerProbeProgressHeader}>
        <Text as="span" tone="muted" size="xs">正在验证模型</Text>
        <Text as="span" tone="subtle" size="xs" mono>{probeProgress.completed}/{probeProgress.total}{probeProgress.model ? ` · ${probeProgress.model}` : ""}</Text>
      </div>
      <Progress value={progressValue} label={`模型验证进度 ${probeProgress.completed}/${probeProgress.total}`} />
    </div>}

    <section className={styles.providerSection} aria-labelledby="usable-models-title">
      <div className={styles.providerSectionHeader}>
        <div>
          <Text as="h4" id="usable-models-title" size="sm" weight="bold">可用于识别</Text>
          <Text tone="subtle" size="xs">{discovery ? `${discovery.models.length} 个模型 · 已完成能力筛选` : "检测接口后显示可用模型"}</Text>
        </div>
        <div className={styles.providerSearch} role="search" aria-label="搜索可用于识别的模型">
          <Search size={15} aria-hidden="true" />
          <Input className={styles.providerSearchInput} type="search" aria-label="搜索模型名称或 ID" value={search} onChange={(event) => onSearchChange(event.target.value)} placeholder="搜索名称或 ID" />
          {search && <Button className={styles.providerSearchClear} size="sm" variant="ghost" aria-label="清除模型搜索" onClick={onClearSearch}><X size={14} /></Button>}
        </div>
      </div>
      {discoveryLoading && <div className={styles.providerInlineStatus} role="status" aria-live="polite"><Spinner label="正在读取模型列表" /><Text as="span" tone="subtle" size="xs">正在读取模型列表…</Text></div>}
      {groupedModels.length ? <div className={styles.providerModelGroups}>
        {groupedModels.map(([vendor, vendorModels]) => <details key={vendor} className={styles.providerModelGroup} open>
          <summary>{vendorLabel(vendor)}<span>{vendorModels.length} 个</span></summary>
          <div className={styles.providerModelRows}>
            {vendorModels.map((model) => <ModelRow key={model.id} model={model} />)}
          </div>
        </details>)}
      </div> : !discoveryLoading && discovery && <div className={styles.providerNoResults}>
        <Text as="span" tone="muted" size="sm">{search ? "没有匹配的模型" : "接口没有返回可用于识别的模型"}</Text>
        {search && <Button size="sm" variant="ghost" onClick={onClearSearch}>清除搜索</Button>}
      </div>}
    </section>

    {pendingVendorGroups.length > 0 && <section className={styles.providerSection} aria-labelledby="pending-models-title">
      <div className={styles.providerSectionHeader}>
        <div>
          <Text as="h4" id="pending-models-title" size="sm" weight="bold">待验证 · {pendingModels.length}</Text>
          <Text tone="subtle" size="xs">选择模型后运行最小图像探针（已选 {selectedPending.length} 个）</Text>
        </div>
      </div>
      <div className={styles.providerPendingGroups}>
        {pendingVendorGroups.map(([vendor, vendorModels]) => {
          const ids = vendorModels.map((model) => model.apiId || model.id);
          const allSelected = ids.length > 0 && ids.every((id) => selectedPending.includes(id));
          return <Surface as="section" compact className={styles.providerPendingGroup} key={vendor} aria-label={`${vendorLabel(vendor)} 待验证模型`}>
            <div className={styles.providerPendingHeader}>
              <Text as="h5" size="sm" weight="bold">{vendorLabel(vendor)} · {vendorModels.length} 个</Text>
              <Button type="button" size="sm" variant="ghost" onClick={() => onTogglePendingVendor(vendor, !allSelected)}>{allSelected ? "取消全选" : "全选"}</Button>
            </div>
            <div className={styles.providerPendingRows}>
              {vendorModels.map((model) => {
                const id = model.apiId || model.id;
                return <Checkbox key={id} label={`${model.label} · ${id}`} checked={selectedPending.includes(id)} onChange={(event) => onTogglePendingModel(id, event.target.checked)} />;
              })}
            </div>
          </Surface>;
        })}
      </div>
    </section>}

    {(failedModels.length > 0 || unsupportedModels.length > 0) && <section className={styles.providerSection} aria-labelledby="failed-models-title">
      <div className={styles.providerSectionHeader}>
        <div>
          <Text as="h4" id="failed-models-title" size="sm" weight="bold">不支持或失败 · {failedModels.length + unsupportedModels.length}</Text>
          <Text tone="subtle" size="xs">失败项可单独重试；不支持项不会进入识别选择器。</Text>
        </div>
      </div>
      <div className={styles.providerFailureList}>
        {failedModels.map((model) => {
          const id = model.apiId || model.id;
          return <div className={styles.providerFailureRow} key={`failed-${id}`}>
            <Text tone="muted" size="sm">{model.label} · <span className={styles.providerFailureId}>{id}</span>{model.capabilityMessage ? ` · ${model.capabilityMessage}` : ""}</Text>
            <Button type="button" size="sm" variant="ghost" disabled={probeBusy} onClick={() => onRetryModel(id)}>重试</Button>
          </div>;
        })}
        {unsupportedModels.map((model) => <Text as="span" key={`unsupported-${model.id}`} tone="subtle" size="xs"><span className={styles.providerFailureId}>{model.id}</span> · {model.reason}</Text>)}
      </div>
    </section>}
  </Surface>;
}

function ModelRow({ model }: { model: ModelData }) {
  const status = modelStatus(model);
  return <article className={styles.providerModelRow}>
    <div className={styles.providerModelRowHeader}>
      <Text as="h5" size="sm" weight="bold">{model.label}</Text>
      <Badge tone={status.tone}>{status.label}</Badge>
    </div>
    <Text as="span" className={styles.providerModelId} tone="subtle" size="xs" mono>{model.id}</Text>
    <Text tone="muted" size="xs">{model.description || "已通过接口能力筛选"} · {model.qualityLabel || "精度暂无数据"} · {model.valueLabel || "价格未知"}</Text>
    {(model.qualitySource || model.qualityUpdatedAt || model.valueSource || model.valueUpdatedAt) && <Text tone="subtle" size="xs">依据：{model.qualitySource || "精度暂无数据"}{model.qualityUpdatedAt ? `（${model.qualityUpdatedAt}）` : ""}{model.valueSource ? `；${model.valueSource}` : ""}{model.valueUpdatedAt ? `（${model.valueUpdatedAt}）` : ""}</Text>}
  </article>;
}

/** Machine-level custom endpoint CRUD and two-stage model capability checks. */
export function CustomProviderSettingsPanel() {
  const setConfig = useProjectStore((state) => state.setConfig);
  const setToast = useUiStore((state) => state.setToast);
  const [providers, setProviders] = useState<CustomProviderSummary[]>([]);
  const [providersLoading, setProvidersLoading] = useState(true);
  const [selectedId, setSelectedId] = useState("");
  const [dialog, setDialog] = useState<"new" | "edit" | "discard" | null>(null);
  const [discardTarget, setDiscardTarget] = useState<"new" | "edit">("new");
  const [draft, setDraft] = useState<ProviderDraft>(EMPTY_DRAFT);
  const [draftDirty, setDraftDirty] = useState(false);
  const [showKey, setShowKey] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [discovery, setDiscovery] = useState<ModelDiscoveryResult | null>(null);
  const [discoveryLoading, setDiscoveryLoading] = useState(false);
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
    setProvidersLoading(true);
    try {
      const api = getSlateSync();
      if (typeof api.settings.listCustomProviders !== "function") return;
      const next = await unwrap(await api.settings.listCustomProviders());
      setProviders(next);
      setSelectedId((previous) => next.some((item) => item.id === previous) ? previous : next[0]?.id || "");
    } catch (cause) {
      setError(appErrorFromUnknown(cause).message);
    } finally { setProvidersLoading(false); }
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
    setDiscoveryLoading(false);
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
    setDiscoveryLoading(true);
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
    } finally {
      if (requestId === discoveryRequestRef.current && selectedIdRef.current === providerId) setDiscoveryLoading(false);
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

  const togglePendingModel = (modelId: string, checked: boolean) => {
    setSelectedPending((previous) => checked
      ? [...new Set([...previous, modelId])]
      : previous.filter((value) => value !== modelId));
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

  // 承接全局设置的分区导航：作为 settings-custom-providers 分区的锚点面板。
  return <Surface as="section" id="settings-custom-providers" className={`${styles.panel} ${styles.helpSection}`} data-testid="custom-provider-settings">
    <div className={styles.sectionHeader}>
      <div>
        <p className={styles.kicker}>连接注册表</p>
        <h2 className={styles.sectionTitle}>自定义模型接口</h2>
      </div>
      <ShieldCheck size={19} aria-hidden="true" />
    </div>
    <Text tone="muted" size="sm">支持任意 OpenAI 兼容 Chat Completions 或 Responses 接口。API Key 可留空；HTTP 地址仅建议用于本机或可信 LAN。</Text>
    {error && <InlineError message={error} />}
    <div className={`${styles.grid} ${styles.customProviderLayout}`}>
      <ProviderRegistryList providers={providers} selectedId={selectedId} loading={providersLoading} onCreate={openNew} onSelect={setSelectedId} />
      <ProviderDetailPanel
        selected={selected}
        discovery={discovery}
        discoveryLoading={discoveryLoading}
        groupedModels={groupedModels}
        search={search}
        pendingModels={pendingModels}
        pendingVendorGroups={pendingVendorGroups}
        selectedPending={selectedPending}
        failedModels={failedModels}
        unsupportedModels={unsupportedModels}
        probeBusy={probeBusy}
        probeProgress={probeProgress}
        onEdit={openEdit}
        onDelete={() => setDeleteTarget(selected)}
        onDiscover={() => void discover(true)}
        onSearchChange={setSearch}
        onClearSearch={() => setSearch("")}
        onProbe={() => void probe()}
        onCancelProbe={() => void cancelProbe()}
        onTogglePendingVendor={togglePendingVendor}
        onTogglePendingModel={togglePendingModel}
        onRetryModel={(modelId) => void retryModel(modelId)}
      />
    </div>
    {dialog && <Dialog open title={dialog === "discard" ? "放弃未保存更改？" : dialog === "new" ? "新增自定义接口" : "编辑自定义接口"} description={dialog === "discard" ? "当前表单仍有未保存内容。" : "连接信息保存到本机全局配置；密钥不会进入普通配置文件。"} onClose={() => { if (dialog === "discard") setDialog(discardTarget); else closeDialog(); }} size="wide" footer={dialog === "discard" ? <Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={() => setDialog(discardTarget)}>继续编辑</Button><Button variant="danger" onClick={() => { setDialog(null); setDraftDirty(false); }}>放弃更改</Button></Stack> : <Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={closeDialog} disabled={busy}>取消</Button><Button type="submit" form="custom-provider-form" loading={busy}>保存接口</Button></Stack>}>
      {dialog === "discard" ? <Text tone="warning">关闭对话框不会自动保存。选择“继续编辑”返回当前表单。</Text> : <form id="custom-provider-form" className={styles.formGrid} noValidate onSubmit={(event) => { event.preventDefault(); void saveDraft(); }}>
        <Field label="接口名称" hint="1–60 字符，忽略大小写后不能重复。"><Input autoFocus value={draft.name} onChange={(event) => updateDraft("name", event.target.value)} /></Field>
        <Field label="Base URL" hint="http(s)，不能包含账号、查询参数或片段。"><Input value={draft.baseUrl} onChange={(event) => updateDraft("baseUrl", event.target.value)} spellCheck={false} /></Field>
        <Field label="请求协议"><Select value={draft.transport} onChange={(event) => updateDraft("transport", event.target.value as ProviderDraft["transport"])}><option value="chat-completions">Chat Completions</option><option value="responses">Responses</option></Select></Field>
        <Field label="JSON 模式"><Select value={draft.jsonMode} onChange={(event) => updateDraft("jsonMode", event.target.value as ProviderDraft["jsonMode"])}><option value="json_schema">JSON Schema</option><option value="json_object">JSON Object</option><option value="prompt">Prompt 约束</option></Select></Field>
        <Field label="图片细节"><Select value={draft.imageDetail} onChange={(event) => updateDraft("imageDetail", event.target.value as ProviderDraft["imageDetail"])}><option value="auto">自动</option><option value="low">低</option><option value="high">高</option><option value="original">原始</option></Select></Field>
        <Field label="API Key" hint={dialog === "edit" ? "留空保留现有 Key；清除使用下方独立动作。" : "留空表示无鉴权接口。"}><div className={styles.secretInputRow}><Input type={showKey ? "text" : "password"} value={draft.apiKey} onChange={(event) => updateDraft("apiKey", event.target.value)} autoComplete="new-password" spellCheck={false} /><Button type="button" size="sm" variant="ghost" aria-label={showKey ? "隐藏 API Key" : "显示 API Key"} title={showKey ? "隐藏 API Key" : "显示 API Key"} aria-pressed={showKey} onClick={() => setShowKey((previous) => !previous)}>{showKey ? <EyeOff size={14} aria-hidden="true" /> : <Eye size={14} aria-hidden="true" />}</Button></div></Field>
        <Field label="手动模型 ID" hint="每行一个；无法读取 /models 时会进入待验证。"><Textarea className="resize-none" value={(draft.manualModelIds || []).join("\n")} onChange={(event) => updateDraft("manualModelIds", event.target.value.split(/[\n,]/).map((id) => id.trim()).filter(Boolean))} placeholder="vendor/vision-model" spellCheck={false} rows={3} /></Field>
        {dialog === "edit" && <Stack direction="row" justify="between" align="center" className={styles.formFieldFull}><Text tone="subtle" size="xs">修改 Base URL、协议、JSON 模式、模型 ID 或 Key 会让旧探针结果失效。</Text><Button type="button" size="sm" variant="ghost" onClick={() => { updateDraft("apiKey", ""); updateDraft("clearApiKey", true); updateDraft("replaceApiKey", true); }}>清除现有 Key</Button></Stack>}
      </form>}
    </Dialog>}
    {deleteTarget && <Dialog open title="删除自定义接口？" description="项目数据库不会被批量修改；引用该接口的项目会显示需要重新选择。" onClose={() => setDeleteTarget(null)} footer={<Stack direction="row" justify="end" gap={2}><Button variant="ghost" onClick={() => setDeleteTarget(null)} disabled={busy}>取消</Button><Button variant="danger" onClick={() => void deleteProvider()} loading={busy}>确认删除</Button></Stack>}><Text tone="warning">将删除「{deleteTarget.name}」的配置、密钥和能力缓存。</Text></Dialog>}
  </Surface>;
}

function vendorLabel(vendor: string): string {
  const labels: Record<string, string> = { anthropic: "Anthropic", deepseek: "DeepSeek", google: "Google", meta: "Meta", minimax: "MiniMax", mistralai: "Mistral AI", openai: "OpenAI", qwen: "Qwen", xai: "xAI", other: "其他" };
  return labels[vendor.toLowerCase()] || vendor.split(/[-_]/).filter(Boolean).map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ") || "其他";
}
