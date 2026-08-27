import { flexRender, getCoreRowModel, useReactTable, type ColumnDef } from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ResolveCsvEdits, ResolveCsvTable } from "../../../shared/contracts/index.js";
import { EmptyState, Text } from "../../design-system";
import { useUiStore } from "../../state";
import styles from "../../app/app.module.css";

interface CsvRow { readonly id: string; readonly index: number; readonly values: readonly string[]; }
type CsvEditKey = `${number}:${number}`;
type PendingCsvEdit = { readonly value: string; committed: boolean };

// This is deliberately shorter than task autosave. It batches keystrokes for
// the virtualized view, while the parent remains the only owner of task dirty
// state and durable writes.
const CELL_COMMIT_DELAY_MS = 250;

export function CsvVirtualTable({ table, edits, onEdit }: { table: ResolveCsvTable | null; edits: ResolveCsvEdits; onEdit: (key: CsvEditKey, value: string) => void }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const density = useUiStore((state) => state.density);
  const onEditRef = useRef(onEdit);
  const pendingEditsRef = useRef<Partial<Record<CsvEditKey, PendingCsvEdit>>>({});
  const commitTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const data = useMemo<CsvRow[]>(() => table?.rows.map((values, index) => ({ id: `source-row-${index}`, index, values })) || [], [table]);

  useEffect(() => { onEditRef.current = onEdit; }, [onEdit]);

  const flushPendingEdits = (key?: CsvEditKey) => {
    const entries = key
      ? [[key, pendingEditsRef.current[key]] as const]
      : Object.entries(pendingEditsRef.current) as ReadonlyArray<readonly [CsvEditKey, PendingCsvEdit | undefined]>;
    let hasUncommittedEdit = false;

    for (const [pendingKey, pendingEdit] of entries) {
      if (!pendingEdit || pendingEdit.committed) continue;
      // Mark before calling outward: a synchronous store update can re-enter
      // this path through React rendering, but it must not duplicate a write.
      pendingEdit.committed = true;
      onEditRef.current(pendingKey, pendingEdit.value);
    }

    for (const pendingEdit of Object.values(pendingEditsRef.current)) {
      if (pendingEdit && !pendingEdit.committed) {
        hasUncommittedEdit = true;
        break;
      }
    }
    if (!hasUncommittedEdit && commitTimerRef.current) {
      clearTimeout(commitTimerRef.current);
      commitTimerRef.current = null;
    }
  };

  const queueEdit = (key: CsvEditKey, value: string) => {
    const existing = pendingEditsRef.current[key];
    if (existing?.value === value && !existing.committed) return;
    pendingEditsRef.current[key] = { value, committed: false };
    if (commitTimerRef.current) clearTimeout(commitTimerRef.current);
    commitTimerRef.current = setTimeout(() => {
      commitTimerRef.current = null;
      flushPendingEdits();
    }, CELL_COMMIT_DELAY_MS);
  };

  const discardQueuedEdit = (key: CsvEditKey) => {
    const pendingEdit = pendingEditsRef.current[key];
    // Escape only cancels a value that has not reached the parent store yet.
    // A value already committed by the debounce is intentionally retained.
    if (pendingEdit && !pendingEdit.committed) delete pendingEditsRef.current[key];
  };

  useEffect(() => {
    for (const [key, pendingEdit] of Object.entries(pendingEditsRef.current) as ReadonlyArray<readonly [CsvEditKey, PendingCsvEdit | undefined]>) {
      // Keep a committed value available to rows that remount before the
      // Zustand-backed props acknowledge it; remove it once acknowledged.
      if (pendingEdit?.committed && edits[key] === pendingEdit.value) delete pendingEditsRef.current[key];
    }
  }, [edits]);

  useEffect(() => {
    // Capture runs ahead of WorkspacePage's bubbling beforeunload handler, so
    // it sees autosave as pending and can include the last typed character.
    const flushBeforeUnload = () => flushPendingEdits();
    window.addEventListener("beforeunload", flushBeforeUnload, true);
    return () => {
      window.removeEventListener("beforeunload", flushBeforeUnload, true);
      flushPendingEdits();
    };
  }, []);

  const columns = useMemo<ColumnDef<CsvRow>[]>(() => (table?.headers || []).map((header, columnIndex) => ({ id: `source-column-${columnIndex}`, header, accessorFn: (row) => row.values[columnIndex] || "", cell: (context) => { const row = context.row.original; const key = `${row.index}:${columnIndex}` as CsvEditKey; const committedValue = edits[key] ?? row.values[columnIndex] ?? ""; const pendingEdit = pendingEditsRef.current[key]; const value = pendingEdit?.value ?? committedValue; return <EditableCell label={`${header} 第 ${row.index + 2} 行`} value={value} committedValue={committedValue} edited={edits[key] !== undefined} onDraftChange={(nextValue) => queueEdit(key, nextValue)} onCommit={(nextValue) => { queueEdit(key, nextValue); flushPendingEdits(key); }} onCancel={() => discardQueuedEdit(key)} />; } })), [edits, table?.headers]);
  const instance = useReactTable({ data, columns, getCoreRowModel: getCoreRowModel(), getRowId: (row) => row.id });
  const rows = instance.getRowModel().rows;
  const headers = instance.getHeaderGroups()[0]?.headers || [];
  // Virtual rows live in a block-level tbody, so the browser cannot infer one
  // shared table layout. Derive every visible width once and reuse it for the
  // colgroup, header cells, and absolutely positioned rows.
  const columnWidths = headers.map((header) => header.column.getSize());
  const tableWidth = columnWidths.reduce((total, width) => total + width, 0);
  const virtualizer = useVirtualizer({ count: rows.length, getScrollElement: () => scrollRef.current, estimateSize: () => density === "compact" ? 36 : 42, overscan: 12 });
  if (!table) return <EmptyState title="还没有 Resolve CSV" description="载入 CSV 后即可预览和编辑。" />;
  if (!table.rows.length) return <EmptyState title="CSV 没有数据行" description="请检查 Resolve CSV 是否只有表头，或重新导出文件。" />;

  return (
    <div className={styles.tableFrame} data-testid="csv-virtual-table">
      <div className={styles.tableToolbar}>
        <Text tone="muted" size="sm">{table.rows.length.toLocaleString("zh-CN")} 行 · {table.headers.length} 列</Text>
        <Text tone="subtle" size="xs">修改后离开单元格即可保存</Text>
      </div>
      <div ref={scrollRef} className={styles.tableScroll}>
        {/* The canvas makes the fixed metadata width contribute to the
            scrollport even though virtual rows use a block-level tbody. */}
        <div className={styles.tableCanvas} style={{ width: `${tableWidth}px` }}>
          <table className={styles.table}>
            <colgroup>
              {headers.map((header, columnIndex) => (
                <col key={header.id} style={{ width: `${columnWidths[columnIndex]}px` }} />
              ))}
            </colgroup>
            <thead>
              <tr>
                {headers.map((header, columnIndex) => (
                  <th key={header.id} scope="col" style={{ width: `${columnWidths[columnIndex]}px` }}>
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative", display: "block" }}>
              {virtualizer.getVirtualItems().map((virtualRow) => {
                const row = rows[virtualRow.index];
                if (!row) return null;
                return (
                  <tr
                    key={row.id}
                    data-index={virtualRow.index}
                    style={{
                      position: "absolute",
                      top: 0,
                      left: 0,
                      width: "100%",
                      height: `${virtualRow.size}px`,
                      transform: `translateY(${virtualRow.start}px)`,
                      display: "table",
                      tableLayout: "fixed",
                    }}
                  >
                    {row.getVisibleCells().map((cell) => (
                      <td key={cell.id} style={{ width: `${columnWidths[cell.column.getIndex()]}px` }}>
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </td>
                    ))}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

export function EditableCell({ label, value, committedValue = value, edited, onCommit, onDraftChange, onCancel }: { readonly label: string; readonly value: string; readonly committedValue?: string; readonly edited: boolean; readonly onCommit: (value: string) => void; readonly onDraftChange?: (value: string) => void; readonly onCancel?: () => void }) {
  const [draft, setDraft] = useState(value);
  const cancelBlurRef = useRef(false);
  const composingRef = useRef(false);
  useEffect(() => setDraft(value), [value]);
  const commit = () => {
    if (cancelBlurRef.current) {
      cancelBlurRef.current = false;
      return;
    }
    if (draft !== value) onCommit(draft);
  };
  return <input className={styles.tableCellInput} data-edited={edited || undefined} aria-label={label} value={draft} onChange={(event) => {
    const nextDraft = event.target.value;
    setDraft(nextDraft);
    onDraftChange?.(nextDraft);
  }} onCompositionStart={() => { composingRef.current = true; }} onCompositionEnd={() => { composingRef.current = false; }} onBlur={commit} onKeyDown={(event) => {
    // Enter/Escape belong to the IME while composition is active. Blurring
    // here would save or discard a partially composed CJK value.
    if (composingRef.current || event.nativeEvent.isComposing || event.key === "Process") return;
    if (event.key === "Escape") {
      // Escape abandons only the uncommitted local draft; the persisted sparse
      // edit remains untouched until the user explicitly replaces it.
      cancelBlurRef.current = true;
      onCancel?.();
      setDraft(committedValue);
      event.currentTarget.blur();
    }
    if (event.key === "Enter") event.currentTarget.blur();
  }} />;
}
