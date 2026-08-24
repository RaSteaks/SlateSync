import { useVirtualizer } from "@tanstack/react-virtual";
import { FileClock, Plus, RefreshCw, RotateCcw, Trash2 } from "lucide-react";
import { useRef } from "react";
import { Button, EmptyState, IconButton, Stack, Text } from "../../design-system";
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
  const saveState = useTaskStore((state) => state.saveState);
  const scrollRef = useRef<HTMLDivElement>(null);
  // A project may contain thousands of task snapshots. Virtualizing this rail
  // keeps selection and save-state updates independent of total history size.
  const virtualizer = useVirtualizer({
    count: tasks.length,
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

      {tasks.length === 0 ? (
        <EmptyState icon={FileClock} title="还没有任务" description="新建任务即可开始。" />
      ) : (
        <div ref={scrollRef} className={styles.taskRail}>
          <div className={styles.taskVirtualSizer} style={{ height: virtualizer.getTotalSize() }}>
            {virtualizer.getVirtualItems().map((virtualRow) => {
              const task = tasks[virtualRow.index];
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
