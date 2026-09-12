import { ArrowDown, ArrowUp, Save } from "lucide-react";
import { useMemo } from "react";
import type { ExportOptions } from "../../../shared/contracts/index.js";
import { Button, Checkbox, Field, Input, Select, Stack, Text } from "../../design-system";
import styles from "../../app/app.module.css";

// @ts-expect-error Shared browser module intentionally has no generated declarations.
import { mergeExportOptions, normalizeExportOptions } from "../../../../public/export-options.js";

const columnLabels: Record<string, string> = {
  scene: "场次",
  shot: "镜号",
  take: "条次",
  comments: "Comments",
  takeStatus: "条次状态",
  cardNumber: "卡号",
  videoCode: "视频码",
  sourcePage: "来源页",
};

export interface ExportOptionsPanelProps {
  readonly options: ExportOptions;
  readonly onChange: (options: ExportOptions) => void;
  readonly disabled?: boolean;
  readonly title?: string;
  readonly description?: string;
  readonly sourceLabel?: string;
  readonly onSaveProjectDefault?: (() => void) | undefined;
  readonly onClearOverride?: (() => void) | undefined;
}

/**
 * Controlled export editor shared by project defaults and per-task overrides.
 * It never starts a Worker request; callers own persistence and preview timing.
 */
export function ExportOptionsPanel({
  options,
  onChange,
  disabled = false,
  title = "CSV 导出选项",
  description = "预览与最终保存共用同一组字段、编码和文件名规则。",
  sourceLabel,
  onSaveProjectDefault,
  onClearOverride,
}: ExportOptionsPanelProps) {
  const normalized = useMemo<ExportOptions>(() => normalizeExportOptions(options) as ExportOptions, [options]);
  const encoding = normalized.format.encoding || "utf-16le";
  const lineEnding = normalized.format.lineEnding || "\r\n";
  const patch = (value: Partial<ExportOptions>) => onChange(normalizeExportOptions(mergeExportOptions(normalized, value)));
  const updateFormat = (value: Partial<ExportOptions["format"]>) =>
    patch({ format: { ...normalized.format, ...value } });
  const moveColumn = (index: number, direction: -1 | 1) => {
    const nextIndex = index + direction;
    if (nextIndex < 0 || nextIndex >= normalized.columns.length) return;
    const columns = normalized.columns.map((column) => ({ ...column }));
    const current = columns[index];
    const next = columns[nextIndex];
    if (!current || !next) return;
    [columns[index], columns[nextIndex]] = [next, current];
    patch({ columns });
  };

  return <div className={styles.exportOptionsPanel} data-export-options-source={sourceLabel || undefined}>
    <div className={styles.sectionHeader}>
      <div>
        <p className={styles.kicker}>{sourceLabel ? `${sourceLabel} · 导出` : "CSV 导出"}</p>
        <h2 className={styles.sectionTitle}>{title}</h2>
      </div>
      <Stack direction="row" gap={2} align="center">
        {onClearOverride && <Button type="button" variant="ghost" size="sm" onClick={onClearOverride} disabled={disabled}>恢复项目默认</Button>}
        {onSaveProjectDefault && <Button type="button" variant="ghost" size="sm" onClick={onSaveProjectDefault} disabled={disabled} startIcon={<Save size={14} />}>保存为项目默认</Button>}
      </Stack>
    </div>
    <Text tone="muted" size="sm">{description}</Text>
    <div className={styles.exportOptionsGrid}>
      <Field label="文件名模板" hint="支持 {project}、{source}、{date}、{time}。">
        <Input value={normalized.filenameTemplate} onChange={(event) => patch({ filenameTemplate: event.target.value })} disabled={disabled} />
      </Field>
      <Field label="输出编码">
        <Select value={encoding} onChange={(event) => updateFormat({ encoding: event.target.value as NonNullable<ExportOptions["format"]["encoding"]> })} disabled={disabled}>
          <option value="utf-8">UTF-8</option>
          <option value="utf-16le">UTF-16 LE</option>
          <option value="utf-16be">UTF-16 BE</option>
        </Select>
      </Field>
      <Field label="分隔符">
        <Input value={normalized.format.delimiter} maxLength={4} onChange={(event) => updateFormat({ delimiter: event.target.value })} disabled={disabled} />
      </Field>
      <Field label="换行">
        <Select value={lineEnding} onChange={(event) => updateFormat({ lineEnding: event.target.value as NonNullable<ExportOptions["format"]["lineEnding"]> })} disabled={disabled}>
          {/* JSX attributes need JS expressions to preserve actual newline bytes. */}
          <option value={"\r\n"}>CRLF · Windows</option>
          <option value={"\n"}>LF · Unix</option>
          <option value={"\r"}>CR · Classic Mac</option>
        </Select>
      </Field>
    </div>
    <Stack direction="row" gap={4} wrap align="center" style={{ marginTop: 12 }}>
      <Checkbox label="写入 BOM" checked={normalized.format.bom} onChange={(event) => updateFormat({ bom: event.target.checked })} disabled={disabled} />
      <Checkbox label="末尾追加换行" checked={normalized.format.finalNewline} onChange={(event) => updateFormat({ finalNewline: event.target.checked })} disabled={disabled} />
    </Stack>
    <div className={styles.exportColumnList} aria-label="导出列顺序">
      <Text size="xs" tone="subtle">勾选列并用箭头调整顺序</Text>
      {normalized.columns.map((column, index) => <div className={styles.exportColumnRow} key={column.key}>
        <Checkbox label={columnLabels[column.key] || column.key} checked={column.enabled} onChange={(event) => patch({ columns: normalized.columns.map((item) => item.key === column.key ? { ...item, enabled: event.target.checked } : item) })} disabled={disabled} />
        <Input aria-label={`${columnLabels[column.key] || column.key} 列标题`} value={column.header} onChange={(event) => patch({ columns: normalized.columns.map((item) => item.key === column.key ? { ...item, header: event.target.value } : item) })} disabled={disabled} />
        <Button type="button" variant="ghost" size="sm" aria-label={`上移${columnLabels[column.key] || column.key}`} onClick={() => moveColumn(index, -1)} disabled={disabled || index === 0} startIcon={<ArrowUp size={14} />} />
        <Button type="button" variant="ghost" size="sm" aria-label={`下移${columnLabels[column.key] || column.key}`} onClick={() => moveColumn(index, 1)} disabled={disabled || index === normalized.columns.length - 1} startIcon={<ArrowDown size={14} />} />
      </div>)}
    </div>
  </div>;
}
