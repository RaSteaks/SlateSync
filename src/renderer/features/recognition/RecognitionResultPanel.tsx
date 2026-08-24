import { CheckCircle2, FileWarning, Plus, Trash2 } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { RecognitionRecord } from "../../../shared/contracts/index.js";
import { Badge, Button, IconButton, InlineError, Input, Stack, Surface, Text } from "../../design-system";
import { useRecognitionStore } from "../../state";
import styles from "../../app/app.module.css";

const fields = [
  ["cardNumber", "卡号"],
  ["videoCode", "视频码"],
  ["scene", "场次"],
  ["shot", "镜"],
  ["take", "次"],
  ["takeStatus", "状态"],
  ["shotSize", "景别"],
  ["cameraPosition", "机位"],
  ["description", "描述"],
  ["comments", "备注"],
] as const;
type EditableRecordField = (typeof fields)[number][0];
type PendingRecordEdit = { readonly recordId: string; readonly field: EditableRecordField; readonly value: string; committed: boolean };

// Keystrokes are coalesced before the Workspace autosave callback runs. The
// shorter queue keeps table input responsive without creating a second writer.
const RECORD_CELL_COMMIT_DELAY_MS = 250;

export function RecognitionResultPanel({ onRecordEdited }: { readonly onRecordEdited?: () => void }) {
  const records = useRecognitionStore((state) => state.records);
  const result = useRecognitionStore((state) => state.data?.result || null);
  const error = useRecognitionStore((state) => state.error);
  const updateRecord = useRecognitionStore((state) => state.updateRecord);
  const addRecord = useRecognitionStore((state) => state.addRecord);
  const removeRecord = useRecognitionStore((state) => state.removeRecord);
  const [search, setSearch] = useState("");
  const headingRef = useRef<HTMLHeadingElement>(null);
  const hadResultRef = useRef(false);
  const recordsRef = useRef(records);
  const updateRecordRef = useRef(updateRecord);
  const onRecordEditedRef = useRef(onRecordEdited);
  const pendingEditsRef = useRef(new Map<string, PendingRecordEdit>());
  const commitTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const query = search.trim().toLowerCase();
  const visibleRecords = records.filter((record) => !query || fields.some(([key]) => String(record[key] || "").toLowerCase().includes(query)));

  useEffect(() => {
    recordsRef.current = records;
    updateRecordRef.current = updateRecord;
    onRecordEditedRef.current = onRecordEdited;

    for (const [key, pendingEdit] of pendingEditsRef.current) {
      const record = records.find((item) => item.id === pendingEdit.recordId);
      if (!record || (pendingEdit.committed && String(record[pendingEdit.field] || "") === pendingEdit.value)) pendingEditsRef.current.delete(key);
    }
  }, [onRecordEdited, records, updateRecord]);

  const flushPendingEdits = (key?: string) => {
    const entries = key
      ? [[key, pendingEditsRef.current.get(key)] as const]
      : [...pendingEditsRef.current.entries()];
    let changed = false;

    for (const [pendingKey, pendingEdit] of entries) {
      if (!pendingEdit || pendingEdit.committed) continue;
      const recordIndex = recordsRef.current.findIndex((record) => record.id === pendingEdit.recordId);
      if (recordIndex < 0) {
        pendingEditsRef.current.delete(pendingKey);
        continue;
      }
      // Flag first so a synchronous Zustand update cannot cause this draft to
      // be submitted again before the record prop acknowledges it.
      pendingEdit.committed = true;
      updateRecordRef.current(recordIndex, { [pendingEdit.field]: pendingEdit.value || null });
      changed = true;
    }

    if (changed) onRecordEditedRef.current?.();
    if (![...pendingEditsRef.current.values()].some((pendingEdit) => !pendingEdit.committed) && commitTimerRef.current) {
      clearTimeout(commitTimerRef.current);
      commitTimerRef.current = null;
    }
  };

  const queueEdit = (record: RecognitionRecord, field: EditableRecordField, value: string) => {
    const key = `${record.id}:${field}`;
    const existing = pendingEditsRef.current.get(key);
    if (existing?.value === value) return;
    pendingEditsRef.current.set(key, { recordId: record.id, field, value, committed: false });
    if (commitTimerRef.current) clearTimeout(commitTimerRef.current);
    commitTimerRef.current = setTimeout(() => {
      commitTimerRef.current = null;
      flushPendingEdits();
    }, RECORD_CELL_COMMIT_DELAY_MS);
  };

  const discardQueuedEdit = (record: RecognitionRecord, field: EditableRecordField) => {
    const key = `${record.id}:${field}`;
    const pendingEdit = pendingEditsRef.current.get(key);
    // Preserve an already submitted value: Escape has always meant cancel the
    // current local draft, rather than undo a completed record edit.
    if (pendingEdit && !pendingEdit.committed) pendingEditsRef.current.delete(key);
  };

  useEffect(() => {
    // Use capture so WorkspacePage observes the newly marked autosave state in
    // its bubbling beforeunload listener and can flush the final edit safely.
    const flushBeforeUnload = () => flushPendingEdits();
    window.addEventListener("beforeunload", flushBeforeUnload, true);
    return () => {
      window.removeEventListener("beforeunload", flushBeforeUnload, true);
      flushPendingEdits();
    };
  }, []);

  useEffect(() => {
    if (result && !hadResultRef.current) headingRef.current?.focus({ preventScroll: false });
    hadResultRef.current = Boolean(result);
  }, [result]);

  if (error) return <Surface className={styles.panel}><InlineError message={error.message} /></Surface>;
  if (!result) return <Surface className={styles.panel}><div className={styles.routeHint}>识别完成后在这里核对结果。</div></Surface>;

  const appendRecord = () => {
    addRecord({ id: globalThis.crypto?.randomUUID?.() || `manual-${Date.now()}`, sourcePage: null, cardNumber: null, videoCode: null, scene: null, shot: null, take: null, takeStatus: null, description: null, comments: null, shotSize: null, cameraPosition: null, confidence: "medium" });
    onRecordEdited?.();
  };

  const editRecord = (record: RecognitionRecord, patch: Partial<RecognitionRecord>) => {
    const originalIndex = records.indexOf(record);
    if (originalIndex < 0) return;
    updateRecord(originalIndex, patch);
    onRecordEdited?.();
  };

  const deleteRecord = (record: RecognitionRecord) => {
    const originalIndex = records.indexOf(record);
    if (originalIndex < 0) return;
    removeRecord(originalIndex);
    onRecordEdited?.();
  };

  return <Surface className={styles.panel} aria-labelledby="recognition-results-title">
    <Stack direction="row" justify="between" align="center" wrap>
      <div><p className={styles.kicker}>识别结果</p><h2 ref={headingRef} tabIndex={-1} id="recognition-results-title" className={styles.sectionTitle}>{result.sheetTitle || "识别明细"}</h2><Text tone="muted" size="sm">{records.length} 条记录 · {result.warnings.length} 个警告</Text></div>
      <Stack direction="row" gap={2} align="center"><Badge tone={result.warnings.length ? "warning" : "success"} icon={result.warnings.length ? FileWarning : CheckCircle2}>{result.warnings.length ? `${result.warnings.length} 个警告` : "结果可用"}</Badge><Button variant="ghost" size="sm" onClick={appendRecord} startIcon={<Plus size={14} />}>添加记录</Button></Stack>
    </Stack>
    {result.warnings.length > 0 && <div className={`${styles.warningList} ${styles.topGap}`}>{result.warnings.map((warning, index) => <div className={styles.warningItem} key={`${warning}-${index}`}>{warning}</div>)}</div>}
    <div className={`${styles.statusRow} ${styles.resultControls}`}><div className={styles.searchWrap}><Input type="search" aria-label="搜索识别记录" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索卡号、视频码、场次、镜或次" /></div><Text tone="subtle" size="xs">显示 {visibleRecords.length} / {records.length}</Text></div>
    <div className={styles.resultTableFrame}>
      <div className={styles.resultTableScroll}>
        <table className={styles.resultTable}>
          <caption className={styles.srOnly}>场记单识别结果，可直接编辑单元格</caption>
          <thead><tr><th scope="col">页</th>{fields.map(([, label]) => <th scope="col" key={label}>{label}</th>)}<th scope="col">置信度</th><th scope="col"><span className={styles.srOnly}>操作</span></th></tr></thead>
          <tbody>{visibleRecords.map((record) => <tr key={record.id} data-low={record.confidence === "low" || undefined}>
            <td className={styles.resultPageCell}>{record.sourcePage || "—"}</td>
            {fields.map(([key, label]) => {
              const pendingKey = `${record.id}:${key}`;
              const committedValue = String(record[key] || "");
              const value = pendingEditsRef.current.get(pendingKey)?.value ?? committedValue;
              return <td key={key} data-wide={key === "description" || key === "comments" || undefined}><ResultEditableCell label={`${label}，第 ${record.sourcePage || "未知"} 页`} value={value} committedValue={committedValue} onDraftChange={(nextValue) => queueEdit(record, key, nextValue)} onCommit={(nextValue) => { queueEdit(record, key, nextValue); flushPendingEdits(pendingKey); }} onCancel={() => discardQueuedEdit(record, key)} /></td>;
            })}
            <td><select className={styles.resultCellSelect} aria-label={`置信度，第 ${record.sourcePage || "未知"} 页`} value={record.confidence} onChange={(event) => editRecord(record, { confidence: event.target.value as RecognitionRecord["confidence"] })}><option value="high">高</option><option value="medium">中</option><option value="low">低</option></select></td>
            <td><IconButton label="删除记录" size="sm" onClick={() => deleteRecord(record)}><Trash2 size={14} aria-hidden="true" /></IconButton></td>
          </tr>)}</tbody>
        </table>
      </div>
    </div>
  </Surface>;
}

export function ResultEditableCell({ label, value, committedValue = value, onCommit, onDraftChange, onCancel }: { readonly label: string; readonly value: string; readonly committedValue?: string; readonly onCommit: (value: string) => void; readonly onDraftChange?: (value: string) => void; readonly onCancel?: () => void }) {
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
  return <input className={styles.resultCellInput} aria-label={label} value={draft} onChange={(event) => {
    const nextDraft = event.target.value;
    setDraft(nextDraft);
    onDraftChange?.(nextDraft);
  }} onCompositionStart={() => { composingRef.current = true; }} onCompositionEnd={() => { composingRef.current = false; }} onBlur={commit} onKeyDown={(event) => {
    // Do not turn an IME confirmation/cancellation key into a table action.
    // Chinese, Japanese, and Korean users must finish composition first.
    if (composingRef.current || event.nativeEvent.isComposing || event.key === "Process") return;
    if (event.key === "Escape") {
      // The ensuing blur belongs to cancellation and must not commit the stale
      // draft captured by this render.
      cancelBlurRef.current = true;
      onCancel?.();
      setDraft(committedValue);
      event.currentTarget.blur();
    } else if (event.key === "Enter") {
      event.currentTarget.blur();
    }
  }} />;
}
