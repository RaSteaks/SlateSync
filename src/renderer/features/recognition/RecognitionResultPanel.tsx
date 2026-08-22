import { CheckCircle2, Eye, FileWarning, PencilLine } from "lucide-react";
import { useState } from "react";
import { Badge, Button, IconButton, InlineError, Input, Stack, Surface, Text } from "../../design-system";
import { useRecognitionStore } from "../../state";
import styles from "../../app/app.module.css";

const fields = [
  ["cardNumber", "卡号"], ["videoCode", "视频码"], ["scene", "场次"], ["shot", "镜"], ["take", "次"], ["takeStatus", "状态"], ["shotSize", "景别"], ["cameraPosition", "机位"],
] as const;

export function RecognitionResultPanel({ onRecordEdited }: { readonly onRecordEdited?: () => void }) {
  const records = useRecognitionStore((state) => state.records);
  const result = useRecognitionStore((state) => state.data?.result || null);
  const error = useRecognitionStore((state) => state.error);
  const updateRecord = useRecognitionStore((state) => state.updateRecord);
  const [search, setSearch] = useState("");
  const [detail, setDetail] = useState(true);
  const visibleRecords = records.filter((record) => !search.trim() || fields.some(([key]) => String(record[key] || "").toLowerCase().includes(search.trim().toLowerCase())));
  if (error) return <Surface className={styles.panel}><InlineError message={error.message} /></Surface>;
  if (!result) return <Surface className={styles.panel}><div className={styles.routeHint}>识别结果会在这里出现。保持原始页顺序，低可信度字段需要人工核对。</div></Surface>;

  return <Surface className={styles.panel} aria-labelledby="recognition-results-title"><Stack direction="row" justify="between" align="center" wrap><div><p className={styles.kicker}>RECOGNITION RESULT</p><h2 id="recognition-results-title" className={styles.sectionTitle}>{result.sheetTitle || "识别明细"}</h2><Text tone="muted" size="sm">{records.length} 条记录 · {result.warnings.length} 个警告</Text></div><Stack direction="row" gap={2} align="center"><Badge tone={result.warnings.length ? "warning" : "success"} icon={result.warnings.length ? FileWarning : CheckCircle2}>{result.warnings.length ? `${result.warnings.length} 个警告` : "结果可用"}</Badge><Button variant="ghost" size="sm" onClick={() => setDetail((value) => !value)} startIcon={<Eye size={14} />}>{detail ? "收起" : "展开"}</Button></Stack></Stack>{result.warnings.length > 0 && <div className={`${styles.warningList} ${styles.topGap}`}>{result.warnings.map((warning, index) => <div className={styles.warningItem} key={`${warning}-${index}`}>{warning}</div>)}</div>}<div className={`${styles.statusRow} ${styles.resultControls}`}><div className={styles.searchWrap}><Input type="search" aria-label="搜索识别记录" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索卡号、视频码、场次、镜或次" /></div><Text tone="subtle" size="xs">显示 {visibleRecords.length} / {records.length}</Text></div>{detail && <div className={styles.recordGrid}>{visibleRecords.map((record) => { const originalIndex = records.indexOf(record); const low = record.confidence === "low"; return <RecordCard key={record.id || `record-${originalIndex}`} record={record} low={low} onChange={(patch) => { updateRecord(originalIndex, patch); onRecordEdited?.(); }} />; })}</div>}</Surface>;
}

function RecordCard({ record, low, onChange }: { record: import("../../../shared/contracts/index.js").RecognitionRecord; low: boolean; onChange: (patch: Partial<import("../../../shared/contracts/index.js").RecognitionRecord>) => void }) {
  const [editing, setEditing] = useState(false);
  return <article className={styles.recordCard} data-low={low || undefined}><Stack direction="row" justify="between" align="center"><Text tone="subtle" size="xs" mono>#{record.sourcePage || "—"} / {record.id.slice(0, 6)}</Text><Stack direction="row" gap={2} align="center"><Badge tone={low ? "warning" : record.confidence === "high" ? "success" : "neutral"}>{record.confidence}</Badge><IconButton label="编辑记录" size="sm" onClick={() => setEditing((value) => !value)}><PencilLine size={14} /></IconButton></Stack></Stack>{editing ? <div className={`${styles.grid} ${styles.recordEditGrid}`}>{fields.slice(0, 6).map(([key, label]) => <label className={styles.recordField} key={key}><span>{label}</span><Input aria-label={`${label}字段`} value={String(record[key] || "")} onChange={(event) => onChange({ [key]: event.target.value || null })} /></label>)}</div> : <div className={styles.recordValueGrid}>{fields.map(([key, label]) => <div className={styles.recordField} key={key}><span>{label}</span><strong title={String(record[key] || "—")}>{String(record[key] || "—")}</strong></div>)}</div>}</article>;
}
