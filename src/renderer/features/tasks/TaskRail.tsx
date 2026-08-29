import { useVirtualizer } from "@tanstack/react-virtual";
import { FileClock, Plus, RefreshCw, RotateCcw, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { TaskListItem } from "../../../shared/contracts/index.js";
import { Button, EmptyState, IconButton, InlineError, Input, Stack, Text } from "../../design-system";
import { useTaskStore } from "../../state";
import styles from "../../app/app.module.css";

function taskLabel(filename: string | null | undefined, id: string | undefined) {
  return filename || (id ? `任务 ${id.slice(0, 8)}` : "未命名任务");
}

const saveStateLabel = {
  idle: "未修改",
  dirty: "等待保存",
  saving: "正在保存",
  saved: "已保存",
  error: "保存失败",
} as const;

function taskStatusLabel(status: string | null | undefined) {
  if (status === "completed") return "已完成";
  if (status === "edited") return "已编辑";
  if (status === "running") return "进行中";
  if (status === "failed") return "失败";
  if (status === "draft" || !status) return "草稿";
  return status;
}

function taskSearchText(task: TaskListItem) {
  return [taskLabel(task.filename, task.id), task.id, taskStatusLabel(task.status)]
    .filter(Boolean)
    .join(" ")
    .toLocaleLowerCase("zh-CN");
}

interface TaskRailProps {
  readonly onSelect: (id: string) => void;
  readonly onRefresh: () => void;
  readonly onNew: () => void;
  readonly onDelete: (id: string) => void;
  readonly onRetrySave: () => void;
  readonly switching?: boolean;
}

export function TaskRail({ onSelect, onRefresh, onNew, onDelete, onRetrySave, switching = false }: TaskRailProps) {
  const tasks = useTaskStore((state) => state.items);
  const activeId = useTaskStore((state) => state.activeId);
  const loading = useTaskStore((state) => state.loading);
  const taskError = useTaskStore((state) => state.error);
  const saveState = useTaskStore((state) => state.saveState);
  const [search, setSearch] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);
  const query = search.trim().toLocaleLowerCase("zh-CN");
  const visibleTasks = useMemo(
    () => tasks.filter((task) => !query || taskSearchText(task).includes(query)),
    [query, tasks],
  );

  useEffect(() => {
    // A narrower result set must always start at its first row; otherwise a
    // prior scroll position can leave the virtualizer with no visible items.
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
  }, [query]);

  // A project may contain thousands of task snapshots. Virtualizing this rail
  // keeps selection and save-state updates independent of total history size.
  const virtualizer = useVirtualizer({
    count: visibleTasks.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 62,
    overscan: 6,
  });

  return (
    <section aria-labelledby="task-rail-title" aria-busy={loading || switching}>
      <Stack direction="row" justify="between" align="center" style={{ marginBottom: 10 }}>
        <div>
          <p className={styles.kicker}>任务</p>
          <h2 id="task-rail-title" className={styles.sectionTitle}>识别任务</h2>
        </div>
        <Stack direction="row" gap={1} align="center">
          <Button variant="ghost" size="sm" onClick={onNew} disabled={switching} startIcon={<Plus size={14} />}>新建</Button>
          <IconButton label="刷新任务列表" size="sm" onClick={onRefresh} disabled={switching || loading}>
            <RefreshCw size={14} aria-hidden="true" />
          </IconButton>
        </Stack>
      </Stack>

      <div className={styles.taskSaveStatus} role="status" aria-live="polite">
        <Text tone={saveState === "error" ? "danger" : saveState === "saved" ? "success" : "subtle"} size="xs">
          {saveStateLabel[saveState]}
        </Text>
        {saveState === "error" && (
          <Button variant="ghost" size="sm" onClick={onRetrySave} startIcon={<RotateCcw size={13} />}>重试保存</Button>
        )}
      </div>

      {tasks.length > 0 && (
        <div className={styles.taskSearch}>
          <div className={styles.taskSearchRow}>
            <div className={styles.taskSearchControl}>
              <Search size={15} aria-hidden="true" />
              <Input
                type="search"
                className={styles.taskSearchInput || ""}
                aria-label="搜索历史任务"
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Escape" && search) {
                    event.preventDefault();
                    setSearch("");
                  }
                }}
                placeholder="搜索文件名、任务 ID 或状态"
              />
            </div>
            {query && <Button variant="ghost" size="sm" onClick={() => setSearch("")}>清除</Button>}
          </div>
          <Text tone="subtle" size="xs">
            {query ? `匹配 ${visibleTasks.length} / ${tasks.length} 个任务` : `共 ${tasks.length} 个历史任务`}
          </Text>
        </div>
      )}

      {taskError && <InlineError message={taskError.message} onRetry={onRefresh} />}

      {loading && tasks.length === 0 ? (
        <div className={styles.routeHint} role="status">正在加载历史任务…</div>
      ) : taskError && tasks.length === 0 ? null : tasks.length === 0 ? (
        <EmptyState icon={FileClock} title="还没有任务" description="新建任务即可开始。" />
      ) : visibleTasks.length === 0 ? (
        <EmptyState
          icon={Search}
          title="没有匹配任务"
          description="试试文件名、任务 ID 或状态的其他关键词。"
          action={<Button variant="ghost" size="sm" onClick={() => setSearch("")}>清除搜索</Button>}
        />
      ) : (
        <div ref={scrollRef} className={styles.taskRail}>
          <div className={styles.taskVirtualSizer} style={{ height: virtualizer.getTotalSize() }}>
            {virtualizer.getVirtualItems().map((virtualRow) => {
              const task = visibleTasks[virtualRow.index];
              if (!task) return null;
              const key = task.id || `${task.createdAt}-${task.filename}-${virtualRow.index}`;
              return (
                <div
                  key={key}
                  className={styles.taskVirtualRow}
                  style={{ transform: `translateY(${virtualRow.start}px)` }}
                  data-index={virtualRow.index}
                  ref={virtualizer.measureElement}
                >
                  <button
                    type="button"
                    className={styles.taskItem}
                    data-active={task.id === activeId}
                    disabled={!task.id || switching}
                    onClick={() => task.id && onSelect(task.id)}
                  >
                    <span>
                      <strong>{taskLabel(task.filename, task.id)}</strong>
                      <small>{taskStatusLabel(task.status)} · {task.recordCount || 0} 条 · {task.updatedAt ? new Date(task.updatedAt).toLocaleString("zh-CN", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "未保存"}</small>
                    </span>
                    <Text tone="subtle" size="xs" mono>{task.pageCount || 0} 页</Text>
                  </button>
                  {task.id && (
                    <IconButton label={`删除${taskLabel(task.filename, task.id)}`} size="sm" onClick={() => onDelete(task.id!)} disabled={switching}>
                      <Trash2 size={14} aria-hidden="true" />
                    </IconButton>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </section>
  );
}
