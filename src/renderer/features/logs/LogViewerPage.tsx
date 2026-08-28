import { Activity, AlertTriangle, CheckCircle2, Info, RefreshCw, ScrollText, XCircle } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import type { LogEntry, LogLevel, LogsReadRequest } from "../../../shared/contracts/index.js";
import { Badge, Button, EmptyState, Field, Icon, InlineError, Progress, Select, Stack, Surface, Text } from "../../design-system";
import { appErrorFromUnknown, getSlateSync, unwrap } from "../../services/api";
import { useRecognitionStore } from "../../state";
import styles from "../../app/app.module.css";

type LevelFilter = "all" | LogLevel;
type CategoryFilter = "all" | "app" | "recognition";

const LEVEL_LABELS: Record<LevelFilter, string> = {
  all: "全部级别",
  info: "信息",
  warn: "警告及以上",
  error: "仅错误",
};

const CATEGORY_LABELS: Record<CategoryFilter, string> = {
  all: "全部分类",
  app: "应用生命周期",
  recognition: "识别链路",
};

const PHASE_LABELS: Record<string, string> = {
  idle: "等待识别",
  preparing: "准备中",
  running: "识别中",
  stopping: "停止中",
  complete: "已完成",
  canceled: "已停止",
  error: "失败",
};

function phaseLabel(phase: string): string {
  return PHASE_LABELS[phase] || phase || "识别中";
}

function levelLabel(level: LogLevel): string {
  return level === "error" ? "错误" : level === "warn" ? "警告" : "信息";
}

function categoryLabel(category: string): string {
  return category === "recognition" ? "识别" : category === "app" ? "应用" : category;
}

function levelTone(level: LogLevel): "accent" | "warning" | "danger" {
  return level === "error" ? "danger" : level === "warn" ? "warning" : "accent";
}

function progressValue(entry: LogEntry): number | null {
  if (entry.percent === null || entry.percent === undefined || !Number.isFinite(entry.percent)) return null;
  return Math.min(100, Math.max(0, Math.round(entry.percent)));
}

function LogEntryRow({ entry }: { entry: LogEntry }) {
  const percent = progressValue(entry);
  return <article className={styles.logEntry} data-level={entry.level}>
    <div className={styles.logEntryHeader}>
      <Stack direction="row" gap={2} align="center" wrap>
        <Badge tone={levelTone(entry.level)} icon={entry.level === "error" ? XCircle : entry.level === "warn" ? AlertTriangle : Info}>{levelLabel(entry.level)}</Badge>
        <span className={styles.logEntryCategory}>{categoryLabel(entry.category)}</span>
        {entry.phase && <span className={styles.logEntryCategory}>{entry.phase}</span>}
      </Stack>
      <time className={styles.logEntryTime} dateTime={entry.timestamp.replace(" ", "T")}>{entry.timestamp}</time>
    </div>
    <Text className={styles.logEntryMessage} size="sm">{entry.message || "（无消息）"}</Text>
    {percent !== null && <div className={styles.logEntryProgressRow}>
      {/* The bar is decorative; the adjacent text carries the accessible value. */}
      <div className={styles.logEntryProgress} data-testid="log-inline-progress" aria-hidden="true"><span style={{ width: `${percent}%` }} /></div>
      <Text className={styles.logEntryProgressValue} size="xs" mono>{percent}%{entry.completed !== null && entry.total !== null ? ` · ${entry.completed}/${entry.total} 页` : ""}</Text>
    </div>}
  </article>;
}

export function LogViewerPage() {
  const recognition = useRecognitionStore(useShallow((state) => ({
    running: state.running,
    phase: state.phase,
    percent: state.percent,
    completedPages: state.completedPages,
    totalPages: state.totalPages,
    message: state.message,
    warning: state.warning,
    error: state.error,
  })));
  const [level, setLevel] = useState<LevelFilter>("all");
  const [category, setCategory] = useState<CategoryFilter>("all");
  const [entries, setEntries] = useState<readonly LogEntry[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const inFlightRef = useRef(false);
  const requestIdRef = useRef(0);

  const loadEntries = useCallback(async (silent = false) => {
    if (inFlightRef.current) return;
    inFlightRef.current = true;
    const requestId = ++requestIdRef.current;
    if (!silent) setLoading(true);
    try {
      const request: LogsReadRequest = {
        limit: 500,
        ...(level === "all" ? {} : { level }),
        ...(category === "all" ? {} : { category }),
      };
      const result = await unwrap(await getSlateSync().logs.read(request));
      if (requestId !== requestIdRef.current) return;
      setEntries(result.entries);
      setHasMore(result.hasMore);
      setError(null);
    } catch (nextError) {
      if (requestId === requestIdRef.current) setError(appErrorFromUnknown(nextError).message);
    } finally {
      inFlightRef.current = false;
      if (requestId === requestIdRef.current) setLoading(false);
    }
  }, [category, level]);

  useEffect(() => {
    requestIdRef.current += 1;
    void loadEntries();
    const timer = window.setInterval(() => { void loadEntries(true); }, 3000);
    return () => {
      requestIdRef.current += 1;
      window.clearInterval(timer);
    };
  }, [loadEntries]);

  const progressTone = recognition.phase === "error" ? "danger" : recognition.phase === "complete" ? "success" : recognition.running ? "accent" : "neutral";
  const progressVisible = recognition.running || recognition.phase !== "idle";
  const currentError = recognition.error?.message || recognition.warning;

  return <div className={styles.page}>
    <div className={styles.pageHeader}>
      <div>
        <p className={styles.eyebrow}>系统 / 诊断</p>
        <h1 className={styles.heading}>日志查看器</h1>
        <p className={styles.subtitle}>查看应用生命周期与识别链路的本地运行记录。日志只保存在当前设备，不包含 API 密钥或完整请求载荷。</p>
      </div>
      <div className={styles.pageActions}>
        <Button variant="ghost" size="sm" onClick={() => void loadEntries()} loading={loading} startIcon={<RefreshCw size={15} />}>刷新日志</Button>
      </div>
    </div>

    <div className={`${styles.grid} ${styles.gridTwo}`}>
      <Surface className={styles.panel} tone="accent">
        <div className={styles.sectionHeader}><div><p className={styles.kicker}>实时状态</p><h2 className={styles.sectionTitle}>当前识别进度</h2></div><Icon icon={Activity} size={19} /></div>
        {progressVisible ? <Stack gap={3}>
          <Stack direction="row" justify="between" align="center">
            <Badge tone={progressTone} icon={recognition.phase === "error" ? XCircle : recognition.phase === "complete" ? CheckCircle2 : Activity}>{phaseLabel(recognition.phase)}</Badge>
            <Text tone="accent" size="lg" mono weight="bold">{Math.round(recognition.percent)}%</Text>
          </Stack>
          <Progress value={recognition.percent} label="当前识别进度" />
          <Stack direction="row" justify="between" gap={3}>
            <Text tone="muted" size="sm">{recognition.message}</Text>
            {recognition.totalPages > 0 && <Text tone="subtle" size="xs" mono>{recognition.completedPages}/{recognition.totalPages} 页</Text>}
          </Stack>
          {currentError && <Text tone={recognition.error ? "danger" : "warning"} size="xs"><Icon icon={AlertTriangle} size={14} /> {currentError}</Text>}
        </Stack> : <div className={styles.routeHint}>当前没有进行中的识别。开始识别后，这里会实时显示阶段与页数。</div>}
      </Surface>

      <Surface className={styles.panel}>
        <div className={styles.sectionHeader}><div><p className={styles.kicker}>存储策略</p><h2 className={styles.sectionTitle}>本地日志</h2></div><Icon icon={ScrollText} size={19} /></div>
        <Text tone="muted" size="sm">按天写入，保留最近 7 天；日志读取通过 Main 进程完成，页面每 3 秒刷新一次。</Text>
        <Stack direction="row" justify="between" gap={3} style={{ marginTop: 18 }}>
          <Text tone="subtle" size="xs" mono>{entries.length} 条{hasMore ? " · 还有更多" : ""}</Text>
          <Text tone="subtle" size="xs">最新记录优先</Text>
        </Stack>
      </Surface>
    </div>

    <Surface className={styles.panel} style={{ marginTop: "var(--ss-layout-gap)" }}>
      <div className={styles.sectionHeader}><div><p className={styles.kicker}>运行记录</p><h2 className={styles.sectionTitle}>日志列表</h2></div><Text tone="subtle" size="xs">自动刷新 · 3 秒</Text></div>
      <div className={styles.logFilters}>
        <Field label="级别"><Select aria-label="日志级别" value={level} onChange={(event) => setLevel(event.target.value as LevelFilter)}>{Object.entries(LEVEL_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</Select></Field>
        <Field label="分类"><Select aria-label="日志分类" value={category} onChange={(event) => setCategory(event.target.value as CategoryFilter)}>{Object.entries(CATEGORY_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</Select></Field>
      </div>
      {error && <div style={{ marginTop: 14 }}><InlineError message={error} onRetry={() => void loadEntries()} /></div>}
      {loading && !entries.length ? <div className={styles.routeHint} style={{ marginTop: 14 }}>正在读取日志…</div> : entries.length ? <div className={styles.logList}>{entries.map((entry, index) => <LogEntryRow key={`${entry.timestamp}-${index}`} entry={entry} />)}</div> : <EmptyState icon={ScrollText} title="暂无日志" description="应用和识别运行后，记录会出现在这里。" />}
    </Surface>
  </div>;
}
