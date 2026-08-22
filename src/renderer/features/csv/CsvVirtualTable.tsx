import { flexRender, getCoreRowModel, useReactTable, type ColumnDef } from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useMemo, useRef } from "react";
import type { ResolveCsvEdits, ResolveCsvTable } from "../../../shared/contracts/index.js";
import { EmptyState, Text } from "../../design-system";
import styles from "../../app/app.module.css";

interface CsvRow { readonly id: string; readonly index: number; readonly values: readonly string[]; }

export function CsvVirtualTable({ table, edits, onEdit }: { table: ResolveCsvTable | null; edits: ResolveCsvEdits; onEdit: (key: `${number}:${number}`, value: string) => void }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const data = useMemo<CsvRow[]>(() => table?.rows.map((values, index) => ({ id: `source-row-${index}`, index, values })) || [], [table]);
  const columns = useMemo<ColumnDef<CsvRow>[]>(() => (table?.headers || []).map((header, columnIndex) => ({ id: `source-column-${columnIndex}`, header, accessorFn: (row) => row.values[columnIndex] || "", cell: (context) => { const row = context.row.original; const key = `${row.index}:${columnIndex}` as `${number}:${number}`; const value = edits[key] ?? row.values[columnIndex] ?? ""; return <input className={styles.tableCellInput} data-edited={edits[key] !== undefined || undefined} aria-label={`${header} 第 ${row.index + 2} 行`} value={value} onChange={(event) => onEdit(key, event.target.value)} onKeyDown={(event) => { if (event.key === "Escape") { event.currentTarget.value = row.values[columnIndex] || ""; event.currentTarget.blur(); } if (event.key === "Enter") event.currentTarget.blur(); }} />; } })), [edits, onEdit, table?.headers]);
  const instance = useReactTable({ data, columns, getCoreRowModel: getCoreRowModel(), getRowId: (row) => row.id });
  const rows = instance.getRowModel().rows;
  const virtualizer = useVirtualizer({ count: rows.length, getScrollElement: () => scrollRef.current, estimateSize: () => 42, overscan: 12 });
  if (!table) return <EmptyState title="还没有 Resolve CSV" description="载入 Resolve 导出的 CSV 后，Worker 会保留原始表格供识别结果回填。" />;
  if (!table.rows.length) return <EmptyState title="CSV 没有数据行" description="请检查 Resolve CSV 是否只有表头，或重新导出文件。" />;

  return <div className={styles.tableFrame} data-testid="csv-virtual-table"><div className={styles.tableToolbar}><Text tone="muted" size="sm">{table.rows.length.toLocaleString("zh-CN")} 行 · {table.headers.length} 列</Text><Text tone="subtle" size="xs">Worker retained table · sparse edits</Text></div><div ref={scrollRef} className={styles.tableScroll}><table className={styles.table}><thead><tr>{instance.getHeaderGroups()[0]?.headers.map((header) => <th key={header.id}>{flexRender(header.column.columnDef.header, header.getContext())}</th>)}</tr></thead><tbody style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative", display: "block" }}>{virtualizer.getVirtualItems().map((virtualRow) => { const row = rows[virtualRow.index]; if (!row) return null; return <tr key={row.id} data-index={virtualRow.index} style={{ position: "absolute", top: 0, left: 0, width: "100%", height: `${virtualRow.size}px`, transform: `translateY(${virtualRow.start}px)`, display: "table", tableLayout: "fixed" }}>{row.getVisibleCells().map((cell) => <td key={cell.id} style={{ width: `${cell.column.getSize()}px` }}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>)}</tr>; })}</tbody></table></div></div>;
}
