import { FileImage, FileText, Trash2, UploadCloud } from "lucide-react";
import { forwardRef, useEffect, useImperativeHandle, useMemo, useRef } from "react";
import { Button, Icon, InlineError, Progress, Stack, Surface, Text } from "../../design-system";
import { asPreparationError, getPreparationService } from "../../services/preparation-service";
import { createOperationGuard } from "../../services/operation-guard";
import { useProjectStore, useRecognitionStore, useSlateStore } from "../../state";
import styles from "../../app/app.module.css";
import { useFileDrop } from "../../hooks/use-file-drop";
import { validateSlateFile } from "../../validation/input-validation";

export interface SlateInputPanelHandle {
  openPicker(): void;
}

export const SlateInputPanel = forwardRef<SlateInputPanelHandle, { readonly onInputChanged?: () => void }>(function SlateInputPanel({ onInputChanged }, ref) {
  const inputRef = useRef<HTMLInputElement>(null);
  const config = useProjectStore((state) => state.config);
  const filename = useSlateStore((state) => state.filename);
  const fileType = useSlateStore((state) => state.fileType);
  const fileSize = useSlateStore((state) => state.fileSize);
  const pageCount = useSlateStore((state) => state.pageCount);
  const preparing = useSlateStore((state) => state.preparing);
  const progress = useSlateStore((state) => state.preparationProgress);
  const preparationMessage = useSlateStore((state) => state.preparationMessage);
  const error = useSlateStore((state) => state.error);
  const setInput = useSlateStore((state) => state.setInput);
  const clearInput = useSlateStore((state) => state.clearInput);
  const setPreparing = useSlateStore((state) => state.setPreparing);
  const setError = useSlateStore((state) => state.setError);
  const recognition = useRecognitionStore((state) => state.running);
  const preparationGuard = useMemo(() => createOperationGuard(), []);
  useImperativeHandle(ref, () => ({ openPicker: () => inputRef.current?.click() }), []);

  useEffect(() => () => { preparationGuard.invalidate(); getPreparationService().terminate(); }, [preparationGuard]);

  const accept = config?.upload.acceptedTypes || ["image/jpeg", "image/png", "image/webp", "application/pdf"];
  const selectFile = async (file: File | undefined) => {
    if (!file || recognition) return;
    const validation = validateSlateFile(file, { acceptedTypes: accept, ...(config?.upload.maxBytes ? { maxBytes: config.upload.maxBytes } : {}) });
    if (!validation.ok) { setError({ code: "INVALID_FILE", message: validation.message, retryable: false }); return; }
    const type = validation.type || file.type;
    const operationId = preparationGuard.start();
    setError(null); setPreparing(true, 2, "正在读取场记单");
    try {
      const result = await getPreparationService().prepare(file, (nextProgress, message) => { if (preparationGuard.isCurrent(operationId)) setPreparing(true, nextProgress, message); });
      if (!preparationGuard.isCurrent(operationId)) return;
      setInput({ filename: file.name, fileType: type, fileSize: file.size, pageCount: result.pageCount, imageDataGroups: result.imageDataGroups });
      onInputChanged?.();
    } catch (nextError) { if (preparationGuard.isCurrent(operationId)) setError(asPreparationError(nextError)); }
  };
  const { dragging, dropProps } = useFileDrop({ disabled: recognition, onFile: selectFile });

  const removeInput = () => { clearInput(); onInputChanged?.(); };
  // The input panel reports file identity only; actual page imagery belongs to
  // WorkspacePage's single dedicated preview so the slate is never duplicated.
  return <Surface className={styles.panel} aria-labelledby="slate-input-title"><input ref={inputRef} hidden type="file" accept={accept.join(",") + ",.pdf"} onChange={(event) => { const file = event.target.files?.[0]; if (file) void selectFile(file); event.currentTarget.value = ""; }} /><div className={styles.sectionHeader}><div><p className={styles.kicker}>01 / 场记输入</p><h2 id="slate-input-title" className={styles.sectionTitle}>载入场记单</h2></div><Icon icon={fileType === "application/pdf" ? FileText : FileImage} size={18} /></div>{!filename ? <button type="button" className={styles.uploadZone} data-dragging={dragging} {...dropProps} onClick={() => inputRef.current?.click()}><span><span className={styles.uploadIcon}><UploadCloud size={22} /></span><strong>拖入场记单，或点击选择</strong><Text tone="subtle" size="xs">PDF、JPEG、PNG、WebP · 最多 {config?.upload.maxBytes ? (config.upload.maxBytes / 1024 / 1024).toFixed(0) : "20"} MB</Text></span></button> : <div className={styles.fileRow}><div className={styles.fileThumb}><Icon icon={fileType === "application/pdf" ? FileText : FileImage} size={20} /></div><div className={styles.fileCopy}><strong>{filename}</strong><small>{fileType === "application/pdf" ? "PDF" : "图片"} · {(fileSize / 1024 / 1024).toFixed(2)} MB · {pageCount} 页</small></div><Button variant="ghost" size="sm" onClick={removeInput} disabled={recognition} startIcon={<Trash2 size={14} />}>移除</Button></div>}{preparing && <Stack gap={2} style={{ marginTop: 14 }}><Stack direction="row" justify="between"><Text tone="muted" size="xs">{preparationMessage}</Text><Text tone="accent" size="xs" mono>{Math.round(progress)}%</Text></Stack><Progress value={progress} label="场记单准备进度" /></Stack>}{error && <div style={{ marginTop: 14 }}><InlineError message={error.message} onRetry={() => setError(null)} /></div>}</Surface>;
});
