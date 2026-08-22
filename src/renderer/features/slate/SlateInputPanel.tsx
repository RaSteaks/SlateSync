import { FileImage, FileText, ImagePlus, Trash2, UploadCloud } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Button, Icon, InlineError, Progress, Stack, Surface, Text } from "../../design-system";
import { asPreparationError, getPreparationService } from "../../services/preparation-service";
import { createOperationGuard } from "../../services/operation-guard";
import { useProjectStore, useRecognitionStore, useSlateStore } from "../../state";
import styles from "../../app/app.module.css";

export function SlateInputPanel({ onInputChanged }: { readonly onInputChanged?: () => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const config = useProjectStore((state) => state.config);
  const filename = useSlateStore((state) => state.filename);
  const fileType = useSlateStore((state) => state.fileType);
  const fileSize = useSlateStore((state) => state.fileSize);
  const pageCount = useSlateStore((state) => state.pageCount);
  const groups = useSlateStore((state) => state.imageDataGroups);
  const preparing = useSlateStore((state) => state.preparing);
  const progress = useSlateStore((state) => state.preparationProgress);
  const preparationMessage = useSlateStore((state) => state.preparationMessage);
  const error = useSlateStore((state) => state.error);
  const setInput = useSlateStore((state) => state.setInput);
  const clearInput = useSlateStore((state) => state.clearInput);
  const setPreparing = useSlateStore((state) => state.setPreparing);
  const setError = useSlateStore((state) => state.setError);
  const recognition = useRecognitionStore((state) => state.running);
  const [dragging, setDragging] = useState(false);
  const preparationGuard = useMemo(() => createOperationGuard(), []);

  useEffect(() => () => { preparationGuard.invalidate(); getPreparationService().terminate(); }, [preparationGuard]);

  const accept = config?.upload.acceptedTypes || ["image/jpeg", "image/png", "image/webp", "application/pdf"];
  const selectFile = async (file: File | undefined) => {
    if (!file || recognition) return;
    const extension = file.name.toLowerCase().split(".").pop();
    const type = file.type || (extension === "pdf" ? "application/pdf" : extension === "jpg" || extension === "jpeg" ? "image/jpeg" : extension === "png" ? "image/png" : extension === "webp" ? "image/webp" : "");
    if (!accept.includes(type)) { setError({ code: "UNSUPPORTED_FILE", message: "请选择 JPEG、PNG、WebP 或 PDF 场记单。", retryable: false }); return; }
    if (config?.upload.maxBytes && file.size > config.upload.maxBytes) { setError({ code: "FILE_TOO_LARGE", message: `文件超过 ${(config.upload.maxBytes / 1024 / 1024).toFixed(0)} MB 限制。`, retryable: false }); return; }
    const operationId = preparationGuard.start();
    setError(null); setPreparing(true, 2, "正在读取场记单");
    try {
      const result = await getPreparationService().prepare(file, (nextProgress, message) => { if (preparationGuard.isCurrent(operationId)) setPreparing(true, nextProgress, message); });
      if (!preparationGuard.isCurrent(operationId)) return;
      setInput({ filename: file.name, fileType: type, fileSize: file.size, pageCount: result.pageCount, imageDataGroups: result.imageDataGroups, pdfDataUrl: result.pdfDataUrl });
      onInputChanged?.();
    } catch (nextError) { if (preparationGuard.isCurrent(operationId)) setError(asPreparationError(nextError)); }
  };

  const removeInput = () => { clearInput(); onInputChanged?.(); };
  return <Surface className={styles.panel} aria-labelledby="slate-input-title"><div className={styles.sectionHeader}><div><p className={styles.kicker}>01 / SLATE INPUT</p><h2 id="slate-input-title" className={styles.sectionTitle}>载入场记单</h2></div><Icon icon={fileType === "application/pdf" ? FileText : FileImage} size={18} /></div>{!filename ? <label className={styles.uploadZone} data-dragging={dragging} onDragOver={(event) => { event.preventDefault(); setDragging(true); }} onDragLeave={() => setDragging(false)} onDrop={(event) => { event.preventDefault(); setDragging(false); void selectFile(event.dataTransfer.files[0]); }}><input data-slate-upload ref={inputRef} className={styles.uploadInput} type="file" accept={accept.join(",") + ",.pdf"} onChange={(event) => void selectFile(event.target.files?.[0])} /><span><span className={styles.uploadIcon}><UploadCloud size={22} /></span><strong>拖入场记单，或点击选择</strong><Text tone="subtle" size="xs">支持 PDF、JPEG、PNG、WebP · 最多 {config?.upload.maxBytes ? (config.upload.maxBytes / 1024 / 1024).toFixed(0) : "20"} MB</Text></span></label> : <Stack gap={3}><div className={styles.fileRow}><div className={styles.fileThumb}>{groups[0]?.[0] ? <img src={groups[0][0]} alt={`${filename} 第 1 页预览`} /> : <ImagePlus size={20} aria-hidden="true" />}</div><div className={styles.fileCopy}><strong>{filename}</strong><small>{fileType === "application/pdf" ? "PDF" : "图片"} · {(fileSize / 1024 / 1024).toFixed(2)} MB · {pageCount} 页</small></div><Button variant="ghost" size="sm" onClick={removeInput} disabled={recognition} startIcon={<Trash2 size={14} />}>移除</Button></div><div className={styles.preview}><div className={styles.previewPages}>{groups.map((group, index) => <div className={styles.previewPage} key={`${filename}-${index}`}>{group[0] && <img src={group[0]} alt={`${filename} 第 ${index + 1} 页`} />}<span>{String(index + 1).padStart(2, "0")}</span></div>)}</div></div></Stack>}{preparing && <Stack gap={2} style={{ marginTop: 14 }}><Stack direction="row" justify="between"><Text tone="muted" size="xs">{preparationMessage}</Text><Text tone="accent" size="xs" mono>{Math.round(progress)}%</Text></Stack><Progress value={progress} label="场记单准备进度" /></Stack>}{error && <div style={{ marginTop: 14 }}><InlineError message={error.message} onRetry={() => setError(null)} /></div>}</Surface>;
}
